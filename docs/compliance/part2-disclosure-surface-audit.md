# 42 CFR Part 2 — disclosure-surface audit (Phase 1 / December pilot)

**Date:** 2026-09-21 · **Scope:** `lakeraven-ehr` engine at `main` (post-#528)
**Question this answers:** every path by which a record can leave the system, so the
Part 2 obligations can be priced against the surface December *actually* exposes
rather than against a full multi-consumer deployment.

**Why this exists.** ADR 0005 priced Option A (SUD in scope) at ~4–6 dev-months by
assuming egress gating on *every* path — FHIR, bulk export, C-CDA, UI — plus a consent
store, accounting, and notice. Phase 1 is one therapist, one greenfield clinic, no
interoperability (a separately funded 2027 initiative). That is a much narrower surface.
This audit enumerates it so the estimate can be re-derived from evidence.

**Method.** Direct read of routes, controllers, services, and models; every row cites
`file:line`. Claims of "no such path" were verified by negative search, and are stated as
such. **Absence of evidence is called out as UNKNOWN rather than reported as absence.**

---

## 1. Egress paths

| # | Path | Content it can carry | Gate today | Reachable in Phase 1? | Disable-able for Phase 1? |
|---|---|---|---|---|---|
| 1 | **HTML chart UI** — `charts#show`, `screenings#index/show/new`, `demo_visits` (`config/routes.rb:13,17,24,37,39,40`) | Full chart as rendered to the clinician, incl. PHQ-9/GAD-7 items | Session auth + `SessionScopePolicy`; audited via `AuditableClinicalAccess` | **Yes — this IS the therapist's workflow** | **No.** Must stay on |
| 2 | **Bulk EHI export** — `POST/GET/DELETE /exports`, `GET /exports/:id/files/:name` (`routes.rb:76-78`) | **Widest path.** `Patient, AllergyIntolerance, Condition, MedicationRequest, Observation` + audit CSV + configuration + manifest (`ehi_export_service.rb:17-21,29-37`) | `create` → write scope (`exports_controller.rb:27`); `show/destroy/files` → `authorize_export_owner!` (`:15`, `export_files_controller.rb:12`), **fail-closed as of #528** | Yes, if a token has the scope | **Yes** — no Phase 1 therapist workflow needs it |
| 3 | **C-CDA / transitions of care** — `POST /transitions_of_care` (`routes.rb:72`) | `Patient, AllergyIntolerance, Condition, MedicationRequest` (`transitions_of_care_controller.rb:14-15`) | `discloses_clinical_data` + write scope | Only if a referral-out flow is used | **Yes** — interop is out of Phase 1 scope |
| 4 | **FHIR REST read API** — ~20 resource types (`routes.rb:45-67`) incl. `Condition`, `Observation`, `DiagnosticReport`, `CarePlan`, `Encounter`, `AuditEvent` | Per-type record content | SMART scopes, verb-aware + compartment-aware + deny-by-default (#528) | Yes, for any issued token | **Mostly** — the therapist uses the HTML UI, not the API |
| 5 | **SMART launch / discovery** — `.well-known/smart-configuration`, `smart/launch` (`routes.rb:81-82`) | No record content (metadata only) | Public by design | Yes | Keep (metadata only) |
| 6 | **Outbound — GUDID** (`gudid_lookup_service.rb:58-60`) | **Device identifier only**, to FDA. Verified: sends `?di=<device_identifier>`; no patient data | n/a | Only if device lookup used | Yes |
| 7 | **Outbound — VSAC** (`vsac_client.rb:88-97`) | **Value-set OIDs only**, to NLM, with API key. Verified: no patient data | n/a | Terminology only | Yes |
| 8 | **File write** (`measure_import_service.rb:220`) | Measure *definitions* (YAML), not patient data | n/a | Admin/import only | Yes |
| 9 | **Logs** (`patient_repository.rb:71`) | A **DFN** (internal identifier) in a failure warning — no clinical content | Rails logger | Yes | Reduce if desired; low risk |

### Verified-absent paths (negative search)

- **No email / SMS / notification egress.** No `ActionMailer`, mailer, `deliver_*`, Twilio, or SendGrid anywhere in `app/` or `lib/`.
- **No print/download affordance in views.** No `send_data`, `send_file`, or download link in `app/views/`.
- **No other outbound HTTP.** GUDID and VSAC are the only `Net::HTTP` call sites; both are reference lookups.

---

## 2. The path that is *not* in this codebase

**Write-back to the shared RPMS backend.** The engine writes to RPMS through
`RpcSupport`-based gateways: `scheduling_gateway`, `adt_gateway`,
`registration_gateway` (`app/gateways/`). Anything written there is readable by **other
RPMS consumers** (CPRS, VueCentric, BPRM, reporting) and **cannot be gated by this
engine**.

**Today that surface carries no BH clinical content:** the gateways above are
demographic / scheduling / ADT, and **screening responses persist in the engine's own
Postgres table** `lakeraven_ehr_screening_responses` (`screening_response.rb:16-17`,
`schema.rb:153`) — *not* written back to RPMS. The most sensitive Phase 1 content
(PHQ-9/GAD-7, including item 9) therefore stays under this engine's controls.

**⚠ That changes as Phase 1 completes.** Treatment plans (#475) and therapy progress
notes (rpms-rpc#219, TIU documents) are **not built yet** and are expected to write to
RPMS. When they do, Part 2 content lands in the shared backend. **Whether that is a
disclosure depends on the tenancy and access model of the pilot's RPMS instance —
an infrastructure/config question (cloud-rpms#30, rpms-ops#536), not an engine one.**

---

## 2b. Cross-repo path: billing / claims (NOT in this engine)

December scope includes psychotherapy billing (90791/90834/90837). **A claim carries
diagnosis codes to a clearinghouse and payer, which is an outbound disclosure** — and it
lives in the `corvid` RCM engine, not here, so an engine-scoped audit misses it.

**Status today: nothing transmits.** `Corvid::Adapters::Base#submit_claim` raises
`NotImplementedError` (`lib/corvid/adapters/base.rb:230`), as do `check_claim_status` and
the remittance fetch. The clearinghouse integration is a planned seam (corvid#561 claims
end-to-end, Sprint 4; Stedi partner work in corvid#567), **not built code**.

**Why that matters:** the Part 2 posture for claims is still a *design decision*, not a
retrofit. Decide before the seam is written whether an SUD diagnosis may appear on an
outbound claim, and what consent (§2.31) and redisclosure notice (§2.32) must accompany
it. This is the cheapest moment to get it right.

---

## 2c. Tenancy: the question is intra-organizational

"Single tenant" in the sense of *one clinic, never shared with another clinic* is not the
Part 2 question. Part 2 governs **who inside the same organization can read an SUD
record**.

- **December (Phase 1):** one part-time therapist who *is* the Part 2 program. Contained.
- **April (Phase 2):** primary care arrives — nurse-practitioner workflows, front desk,
  billing — all on the same RPMS instance, none of them part of the Part 2 program.
  **That is the cliff.** Read access by non-program staff to SUD records is a disclosure.

**So the operative deadline for #494 / #497 is Phase 2, not December.**

**RPMS can separate natively, and that shrinks the work.** The RPMS behavioral-health
package carries its own security keys and sensitive-record handling, which is exactly the
source #494 already names for the marker ("from the RPMS BH package / visit clinic"). The
marker does not have to be invented — it has to be *derived and respected*.

**"Can separate" ≠ "is separated."** The BH keys and sensitive-record configuration must
actually be set on the pilot instance and **verified on the live system**, not assumed.
That is site configuration (rpms-ops#536, an L3 tribe-owned item) plus a live-dispatch
proof (rpms-rpc#224), not engine code.

---

## 3. Findings

**(a) Must stay on for the December workflow:** path 1 only (the HTML chart UI, including
the screening surface).

**(b) Can be switched off for Phase 1 without breaking the therapist:** paths 2, 3, 4, 6,
7, 8 — bulk export, C-CDA, the FHIR REST read API, and the outbound lookups. This is the
single most consequential finding: **the wide disclosure paths are exactly the ones Phase 1
does not need.**

**(c) UNKNOWN — must be answered by a human, not inferred from code:**
1. **Is the RPMS BH separation actually configured and verified on the pilot instance?**
   RPMS *can* segregate BH records by security key; whether it *does* on this instance is
   site config (rpms-ops#536) and needs a live-dispatch proof (rpms-rpc#224), not an
   assumption. *This is the load-bearing unknown — see §2c.*
2. **Does the clinic "hold itself out as" providing SUD treatment or referral** (the
   §2.11 program test)? A legal/operational question about the service list and marketing,
   not a code question.
3. **Do treatment plans (#475) and TIU notes write Part 2-eligible content to RPMS?**
   Not yet built — decide the target design before building, not after.
4. **May an SUD diagnosis appear on an outbound claim (§2b), and under what consent?**
   The clearinghouse seam is unbuilt; decide before writing it.
5. Whether disabling the FHIR REST API conflicts with any partner/certification
   commitment.

---

## 4. What this implies for the open issues

- **#494 (record-level segmentation)** is narrower than ADR 0005 priced *if* paths 2–4 are
  off for Phase 1. The substrate already exists: the audit-denial mechanism
  (`note_audit_denial`, merged in #512) and the verb/compartment-aware gateway (#528).
  Remaining work is a Part 2 marker on the record plus a filter in the gateway layer.
- **#497 (outbound disclosures consent-gated + accounted + §2.32 notice)** collapses
  substantially if **nothing is disclosed outbound in Phase 1** — which paths 2, 3 and the
  verified-absent list suggest is achievable by configuration. §2.22 notice has a natural
  vehicle in consent capture (#471, Sprint 3).
- **#526 (which security key grants screening scopes)** is currently unanswerable by
  design: `BEHAVIORAL_HEALTH_TYPES = [].freeze` and both `bh_provider` and `bh_supervisor`
  map to it (`session_scope_policy.rb:64,92-93`), so BH keys grant nothing. The mapping
  decision is coupled to whether Part 2 segmentation is record-level (#494) or type-level.

## 5. Corrections from adversarial review (2026-09-23)

Two findings against §1 and §3(b). Neither overturns the re-pricing; both sit on the
path to it, and an estimate that treats them as free is short.

**(a) "Disable-able for Phase 1" is work, not configuration.** `lib/lakeraven/ehr/engine.rb`
defines no feature flags, ENV toggles or config accessors, and `config/routes.rb` mounts
every path unconditionally — there is no switch to set. Turning paths 2–4 off requires
building the mechanism. Small, but not zero, and §3(b) reads as though it were free.

**(b) The "Gate today" column is currently decoration for paths 2–4, and this audit
omits the reason.** #496 is not cited anywhere above. It is open, and the defect is live:
`backend_services_controller.rb:52-56` decodes the client assertion with no signature
verification ("Decode JWT without verification"), and `:34` issues
`scopes: params[:scope] || "system/*.read"` — the caller's requested scope, never
intersected with the application's registered scopes. Its reproduction returns
`POST /transitions_of_care → 201 (full C-CDA)` and `POST /exports → 202`, which are
exactly the paths §3(b) proposes to rely on scopes to close.

The consequence for the fallback control matters more than the omission: "issue no token
carrying those scopes" is not a control while a caller can mint any scope it asks for.

**So the route to "Phase 1 exposes only path 1" is #496 plus a disabling mechanism.**
That makes #496 a December blocker rather than a general-hardening item, which is how the
#494/#496 pairing already framed it.

---

**This audit does not decide the SUD question.** It replaces a 4–6-month estimate built
for a larger system with a concrete, costed surface, and isolates the three human
decisions (§3c) that the estimate actually turns on.
