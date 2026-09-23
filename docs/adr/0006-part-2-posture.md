# ADR 0006: 42 CFR Part 2 posture is a deployment input; segmentation is layered in the engine, never in RPMS

**Status:** Proposed
**Date:** 2026-09-15 · **Rewritten:** 2026-09-23

> **Renumbered.** Drafted as ADR 0005; `0005` is *PHI access audit* on `main`.

## What changed in this rewrite, and why

Earlier drafts of this ADR tried to answer, for a specific launch, whether the
clinic is a 42 CFR Part 2 program — and then recorded the answer here. An
adversarial regulatory review blocked that, correctly: § 2.11 is a fact-specific
test about how a program operates and describes its services, and this codebase
cannot know those facts.

The deeper problem was the coupling, not the reasoning. **This engine is not a
deployment.** It is shipped to more than one organisation, and each one's Part 2
status is a fact about that organisation's service list, marketing, prescribing
and referral practice. An ADR in a shared engine has no standing to make that
finding for anybody, and a determination recorded here would be wrong for the
next deployment even if it were right for the first.

So the determination is removed from this document. **The host declares its
posture; the engine enforces what it is told.** That is the same rule ADR 0001
sets for Rails coupling and ADR 0002 sets for host-configurable policy, applied
to a regulatory posture instead of a UI or a tagging rule.

## Decision

**1. Part 2 posture is a deployment input, not a property of this engine.**
The host declares, per deployment, whether it operates a Part 2 program. The
engine never infers it, never defaults it to "no", and fails closed if it is
unset. Concretely:

- **`part2_program: true`** — the deployment is a Part 2 program. Every Part 2
  obligation that has an engine-side mechanism is enforced.
- **`part2_program: false`** — the deployment is not a Part 2 program. Recipient
  duties still apply to records received from Part 2 programs; native records
  are not segmented.
- **unset** — the engine refuses to serve rather than guessing. An unset posture
  is a configuration error, not a default.

The declaration itself, and the facts supporting it, live with the deployment —
in the private deploy configuration, alongside the tenant identity — **not in
this repository**. This engine records only that the input exists and what it
switches.

**2. Whichever posture is declared, segmentation is enforced in the engine at
the serialization/egress boundary, expressed as DS4P security labels, and never
delegated to RPMS.** RPMS cannot represent it (headline finding below); the
engine's FHIR/C-CDA/export surface is the only place every egress passes
through. Labels live in a PG sidecar keyed to RPMS record identity and are never
written back into RPMS files.

**3. The two postures differ in capability, and they ship on different
schedules.** This is a product-roadmap decision, and unlike a § 2.11 finding it
is ours to make:

| | **Recipient duties** (ships first) | **Program capability** (deferred) |
|---|---|---|
| Applies to | every deployment, both postures | deployments declaring `part2_program: true` |
| Content | preserve inbound `confidentialityCode` / `meta.security`; § 2.32 redisclosure notice; legal-proceedings guard; the HIPAA notice duty adopted 26 Apr 2024 (89 FR 33064), compliance date already passed | SUD classifier, egress gating on every path, § 2.31 consent store, § 2.25 accounting, § 2.22 notice, break-glass |
| Cost | ~2–4 dev-weeks | ~4–6 dev-months |

A deployment that declares `part2_program: true` before the program capability
ships is **not supported** — the engine should say so at boot rather than serve
it. That is the honest form of "the program capability is not ready": a gap in
the product, stated as one, rather than a claim about anybody's clinic.

**4. Deployment preconditions are stated, not assumed.** RPMS-side access
(roll-and-scroll, other RPC clients, printed health summaries, the PCC visit)
bypasses the engine entirely. No engine posture can control it. A deployment
declaring `part2_program: true` therefore requires site-level controls — RPMS
account, menu and security-key governance — as an operational requirement, and
the engine's conformance claims are scoped to its own surfaces. Whether the
RPMS behavioural-health package's separation is actually configured on a given
instance is site configuration plus a live-dispatch proof, never an assumption
(rpms-ops#635, rpms-ops#536, rpms-rpc#224).

**5. Tribal-data overlays are independent gates.** OCAP community authorisation
is required for any SUD-touching aggregate or reporting flow under either
posture; Expert Determination remains the only acceptable de-identification
basis. Part 2 consent never substitutes for either.

## What this ADR deliberately does not do

- **It does not determine whether any deployment is a Part 2 program.** That is
  a fact about an organisation, assessed on its service list, website, community
  materials, licence, referral practice and prescribing. It is answered per
  deployment, by that deployment, with counsel — and recorded with the deploy
  config, off-git.
- **It does not schedule anyone's launch.** The program capability is unbuilt;
  when a deployment needs it, that is a roadmap conversation, not a finding here.
- **It does not restate Part 2.** The regulatory summary below is orientation for
  engineers, was found in review to be incomplete in places (notably the § 2.31
  element list and § 2.12(a)(1)'s conjunctive structure), and is not a
  compliance reference. Counsel governs.

## Context

### Headline finding: RPMS cannot represent the segmentation Part 2 requires

Before anything else in this document: the underlying RPMS/VistA store has **no
record-level sensitivity attribute on the shared clinical files**. What it has:

- A **patient-level** sensitive-record flag (`ORWPT SELCHK` returns `'1' if
  sensitive`; mapped but unused at
  `rpms-rpc/lib/rpms_rpc/mappings/stock_vista.rb:660`). Patient-level is the
  wrong granularity: Part 2 restricts *records about SUD treatment*, not
  *patients*.
- **Package-level** screening in the Behavioral Health package: BH visit data
  lives in the AMH files and the M side screens rows per-user via
  `$$GUIPL^AMHUTIL`, returning `**SENSITIVE**` placeholders for flagged
  patients. That segregates *the BH package's own visit notes* — it does
  nothing for the SUD problem-list entry in the Problem file, the
  buprenorphine order in the Pharmacy files, the toxicology result in the Lab
  files, or the PCC visit that billed the encounter. Those live in general
  files shared with all other care, with no per-record security field.

So any Part 2 segmentation we build is **layered in the engine above a store
that cannot express it**. That changes the build, not just the schedule:

1. The engine's serialization/RPC boundary is the *only* enforcement point.
   There is no DB scope to lean on (all clinical models are RPC-backed
   `ActiveModel` facades — `app/models/lakeraven/ehr/condition.rb`,
   `observation.rb`, `medication_request.rb`, etc.; only bookkeeping tables
   are local PG).
2. Classification cannot be stored where the data lives. Part 2 status must be
   **computed** (value-set classifier over codes/meds/orders) or **stored in a
   sidecar** (local PG table keyed by patient+record identifiers), and either
   way re-derived consistently on every egress path.
3. Every path that bypasses the engine — direct RPMS roll-and-scroll access,
   BMX/CIA RPC clients, health summaries printed at the facility, any future
   IRIS/SQL reporting — bypasses the control entirely. The engine can make
   *its* API compliant; it cannot make the *deployment* compliant. A Part 2
   program running on RPMS needs administrative/operational controls (who gets
   RPMS accounts, which menus/keys) that are out of this engine's reach and
   must be stated as deployment preconditions, not assumed.

### The regulatory state (2024 final rule — not the pre-2024 folklore)

Part 2 was substantially amended by the CARES Act-mandated final rule,
89 FR 12472 (Feb 16, 2024), which aligned Part 2 with HIPAA. **Effective
April 16, 2024; compliance was required by February 16, 2026 — that date has
already passed**, and OCR opened its civil enforcement program and began
accepting Part 2 complaints on Feb 16, 2026. There is no phase-in left to
plan against: if we are subject to Part 2 on the day a clinic opens, we are
subject to an actively-enforced rule on day one.

What the current rule actually says (all quotes from the current eCFR text):

- **Who is covered — the crux.** A "Part 2 program" is a *federally assisted*
  *program* (§ 2.11). "Program" means:

  > "(1) A person (other than a general medical facility) that **holds itself
  > out as providing, and provides, substance use disorder diagnosis,
  > treatment, or referral for treatment**; or (2) An identified unit within a
  > general medical facility that holds itself out as providing, and provides
  > [the same]; or (3) Medical personnel or other staff in a general medical
  > facility **whose primary function** is the provision of substance use
  > disorder diagnosis, treatment, or referral for treatment **and who are
  > identified as such providers**." (42 CFR § 2.11)

  "Federally assisted" (§ 2.12(b)) is met by, among other things, Medicare
  participation, DEA registration "to the extent the controlled substance is
  used in the treatment of substance use disorders", any federal financial
  assistance "including financial assistance which does not directly pay for
  the substance use disorder diagnosis, treatment, or referral", or tax-exempt
  status. **For a tribal health program, federal assistance is effectively a
  given** (IHS/self-determination funding, Medicare, tax exemption). The
  entire question is the "holds itself out as providing, and provides"
  prong — which is decided by service lists, marketing copy, signage, and
  what care is actually delivered, not by anything in this codebase.

  § 2.12(e)(1) confirms the both-directions edge: coverage "includes …
  private practitioners who hold themselves out as providing, and provide"
  SUD care — but does *not* reach, e.g., "emergency room personnel who refer a
  patient to the intensive care unit for an apparent overdose", unless SUD
  care is their primary, identified function.

- **A general BH/mental-health practice that is NOT a Part 2 program may
  document SUD without creating Part 2 records.** § 2.12(d)(2)(ii):

  > "a treating provider who is not subject to this part may record
  > information about a SUD and its treatment that identifies a patient. …
  > The act of recording information about a SUD and its treatment does not by
  > itself render a medical record which is created by a treating provider who
  > is not subject to this part, subject to the restrictions of this part."

- **But records *received from* a Part 2 program still carry obligations.**
  § 2.12(d)(2)(i)(C) applies the restrictions to "[p]ersons who receive
  records directly from a part 2 program … and who are notified of the
  prohibition on redisclosure in accordance with § 2.32" — with a major 2024
  softening:

  > "A part 2 program, covered entity, or business associate that receives
  > records based on a single consent for all treatment, payment, and health
  > care operations **is not required to segregate or segment such records**."

  And per § 2.33(b)(1), a covered entity receiving records under a TPO consent
  "may further disclose those records in accordance with the HIPAA
  regulations, **except for uses and disclosures for civil, criminal,
  administrative, and legislative proceedings against the patient**"
  (that prohibition follows the record to *any* recipient forever —
  § 2.12(d)(1), § 2.13(a)).

- **Consent** (§ 2.31): written (paper or electronic), with patient name,
  who may disclose, a specific description of the information, recipient(s)
  ("my treating providers, health plans, third-party payers, and people
  helping to operate this program" suffices for the **single
  consent for all future TPO uses and disclosures** the 2024 rule created),
  purpose ("for treatment, payment, and health care operations" suffices),
  revocation right, expiration date *or event* ("end of the treatment" or
  "none" suffices for TPO), and signature. Each consented disclosure must be
  accompanied by the § 2.32 redisclosure notice and a copy or clear
  explanation of the consent's scope.

- **Patient notice** (§ 2.22): a Part 2 program must give an NPP-style
  plain-language notice — prescribed header, description of permitted uses,
  the single-TPO-consent statement, revocation, breach-notification duty,
  complaint rights. Compliance deadline was Feb 16, 2026 (passed).

- **Accounting of disclosures** (§ 2.25, new in 2024): on request, all
  consented disclosures for the prior 3 years; for **TPO disclosures, an
  accounting is owed only "where such disclosures are made through an
  electronic health record"** — i.e., *our product is precisely the case
  where the TPO accounting obligation attaches*. Intermediaries owe a
  parallel list-of-disclosures duty (§ 2.24).

- **Breach notification** (§ 2.16(b)): "The provisions of 45 CFR part 160 and
  subpart D of 45 CFR part 164 [the HITECH Breach Notification Rule] shall
  apply to part 2 programs … in the same manner as those provisions apply to
  a covered entity."

- **Penalties** (§ 2.3): violations are now "subject to the applicable
  penalties under sections 1176 and 1177 of the Social Security Act,
  42 U.S.C. 1320d-5 and 1320d-6" — i.e., HIPAA-scale civil money penalties
  and criminal liability, enforced by OCR, replacing the old
  slap-on-the-wrist criminal fine. This is the change that converts "Part 2
  risk" from theoretical to priced.

- **Segmentation standards.** For interchange, the labeling vocabulary
  exists: FHIR `meta.security` with HL7 v3 Confidentiality `R` (restricted)
  and ActCode sensitivity codes (`SUD`, `OPIOIDUD`, `ETH`), and the HL7 FHIR
  Data Segmentation for Privacy (DS4P) IG for carrying Part 2 handling
  obligations (e.g., `NOREDISCLOSEWOCON`, `42CFRPart2`) on resources and
  bundles; C-CDA carries the same semantics via `confidentialityCode` and
  DS4P entry-level tagging. These are how Part 2 data is *marked*; nothing in
  them solves *deciding what to mark*.

### What exists in this engine today

- **Access audit**: `app/controllers/concerns/lakeraven/ehr/auditable_clinical_access.rb`
  writes one immutable `AuditEvent` row per FHIR request (local PG). No
  purpose-of-use, no recipient concept; write failures are swallowed.
- **Accounting of disclosures**: `app/services/lakeraven/ehr/disclosure_service.rb`
  + `Disclosure` model (recipient, purpose, `consent_reference`, 6-year
  retention, ONC (d)(11) / 45 CFR 164.528 shaped). **No production call
  site** — nothing in the FHIR, export, or C-CDA paths records a disclosure.
  Part 2's § 2.25 accounting could extend this machinery, but today it is
  plumbing without pipes.
- **Bulk/EHI export**: `exports_controller.rb` + `EhiExportService` emit
  NDJSON for 17 resource types with **no sensitivity filtering and no
  Disclosure rows**. Bulk export is where segmentation fails silently: a
  single unlabeled `MedicationRequest` for buprenorphine in an NDJSON file
  discloses SUD treatment to whoever holds the export.
- **C-CDA**: `ccda_generator.rb` builds a CCD (allergies, problems, meds,
  vitals, encounters) with **no `confidentialityCode` handling**; the import
  path (`ccda_parser.rb`) likewise drops any inbound confidentiality marking
  on the floor — which matters under **either** posture, because inbound
  documents from an outside SUD program arrive *already labeled* and we
  currently erase the label. Recipient duties do not depend on whether the
  deployment is itself a program.
- **Authorization**: SMART scopes at **resource-type granularity**
  (`authorize_fhir_scope!`), Pundit policies thin. The gap is already
  documented in code: `session_scope_policy.rb` carries a "42 CFR PART 2 —
  READ THIS" header stating plainly that `cprs_gui_chart` grants
  `Observation.read`/`Condition.read` — "the PHQ-9 item-9 answer and the
  substance-use diagnosis" — while the BH keys grant nothing, and that
  "[r]ecord-level segmentation is real work, tracked as #494 and blocking for
  any deployment holding Part 2 content." Separately, #496 (unverified JWT on
  `/oauth/token`) means the backend-services path can mint any scope — any
  Part 2 gate is decoration until #496 closes.
- **Break-glass**: `emergency_access_service.rb` exists (reason codes,
  supervisor review) but holds state in memory.
- **Redaction**: `fhir/redaction_policy.rb` is field-level masking (SSN, DFN,
  tribal enrollment, SOGI) — not record/category suppression; serializers
  default to `view: :full`.
- **Corvid**: consumes clinical data only as a generic FHIR HTTP client
  (`corvid/lib/corvid/adapters/fhir_adapter.rb`); no gem dependency on this
  engine; never persists PHI. For Part 2 purposes corvid sits on the far side
  of a **disclosure boundary**: anything our FHIR API serves it, we have
  disclosed. Since corvid is PHI-minimized and its PRC/RCM workflows are
  payment/health-care-operations, the clean posture is (a) Part 2 records
  reach corvid only under a TPO consent on file, (b) every response carrying
  Part 2 data carries `meta.security` labels + the § 2.32 notice semantics
  (DS4P), and (c) the disclosure is recorded. Corvid-side, nothing persists,
  so no corvid schema change is forced — but corvid's outbound artifacts
  (claims, referral packets to outside payers/providers) become *re*disclosures
  and must carry the notice.

### Signals reviewed

- Issue #291 (this ADR's subject) — filed against this repo but written in
  corvid vocabulary (`Case`/`Determination`/`Task` are corvid models; this
  engine has none of them) and assuming a tag-when-SUD-signal-present design.
  Both need correction here.
- Issue #494 — record-level segmentation, already marked blocking for any
  deployment holding Part 2 content.
- Issue #496 — unverified backend-services JWT; hard prerequisite for any
  claim that a Part 2 gate exists.
- The December launch: behavioral-health clinic (one therapist, mobile-first)
  launches **December 2026**; full primary care waits until **April 1**.
- Tribal-data overlays that do not go away because Part 2 applies: **Expert
  Determination** is required for any de-identified release (Safe Harbor is
  not sufficient for tribal populations), and **OCAP** requires community
  authorization for uses of tribal data. Part 2 consent is *individual*
  consent; OCAP is *community* authorization; Expert Determination governs
  *de-identified* flows (which Part 2 does not reach — § 2.12 restricts
  patient-identifying records). All three overlay independently: a Part 2
  TPO consent does not satisfy OCAP for, say, aggregate SUD reporting, and
  an Expert Determination does not authorize identified Part 2 disclosure.
  Aggregate SUD statistics are among the most community-sensitive artifacts
  we could ever emit; OCAP review of any SUD-touching report path is a
  standing requirement in both branches below.

## Consequences

### Positive

- **A deployment's regulatory status stops being this repository's problem.**
  The engine cannot be wrong about a fact it never asserts, and the same build
  serves an organisation that is a Part 2 program and one that is not.
- **Fail-closed on an unset posture** turns the dangerous default — assuming
  "not a program" because nobody said otherwise — into a boot-time error.
- Recipient duties ship for every deployment regardless of posture, and the
  2024 rule's no-segregation-under-TPO-consent clause (§ 2.12(d)(2)(i)(C))
  means merely *receiving* Part 2 records does not require a shadow
  segmentation engine.
- The label / consent / disclosure plumbing is no-regret: it is the same
  machinery ONC (d)(11) accounting and ordinary HIPAA hygiene want, so shipping
  recipient duties first strands nothing if a deployment later declares
  `part2_program: true`.
- Putting the RPMS-can't-represent-it finding in the architecture (engine-
  boundary enforcement, PG sidecar) prevents the dead-end alternative of waiting
  for a FileMan schema change that will never come.

### Negative

- **The engine can refuse a posture it cannot serve.** A deployment declaring
  `part2_program: true` before the program capability ships gets a boot-time
  refusal. That is honest, and it is also a product gap that will be felt by the
  first organisation that needs it.
- The program capability's cost — months of work plus permanent
  clinical-workflow friction — is unchanged by moving the determination out of
  this document. It is now a roadmap decision rather than a compliance one.
- Engine-boundary enforcement means no deployment-wide compliance claim is
  possible; RPMS-native access (roll-and-scroll, printed summaries, the PCC
  visit) remains a documented residual risk managed operationally.
- A computed classifier will have false negatives at the margins (free-text
  notes referencing SUD, medications with dual indications); the design accepts
  label-at-egress plus curated value sets rather than promising perfection, and
  says so in conformance language.
- **Declaring the posture is now a deployment obligation**, and a deployment
  that gets it wrong gets it wrong quietly. The engine can refuse an unset
  posture; it cannot detect a mistaken one.

### Alternatives considered

- **"Just add a Part 2 flag to the encounter"** (the shape #291's scope list
  implies). Rejected as the *whole* answer. Flagging the encounter leaks the
  fact of SUD treatment through every other door: the problem-list F-code,
  the buprenorphine `MedicationRequest`, the tox-screen `Observation`, the
  note *reference* in a `DocumentReference` list, the visit's billing
  artifacts. Part 2 restricts "any records which would identify a patient as
  having or having had a substance use disorder" (§ 2.12(a)(1)) — identity
  leaks transitively, so classification must be per-record across resource
  types, and egress gating must be closed-world (every serializer, not a
  flag someone remembers to check). An encounter flag survives only as one
  *input* to the classifier.
- **Segregate Part 2 data in a separate store** (shadow DB or second RPMS
  instance). Rejected. Splits the chart clinicians work from, doubles
  write-path complexity against a store we don't own, and the 2024 rule
  explicitly relieves TPO-consent recipients of segregation — the rule asks
  for controlled *disclosure*, not physical separation.
- **Exclude all BH content from the FHIR API until Part 2 is built.**
  Rejected; it's the resource-type granularity mistake `session_scope_policy.rb`
  already warns against — the same `Observation` endpoint serves blood
  pressures, and a control that "looks like" segregation is worse than an
  honest gap.
- **Treat everything as Part 2 regardless of the determination** ("safe"
  maximalism). Rejected. It imports Part 2's consent friction into all of
  primary care, degrades care coordination (the harm the 2024 rule was
  written to reduce), and still doesn't answer the obligations that attach
  only to actual Part 2 programs (§ 2.22 notice, § 2.25 accounting) — you
  cannot comply your way out of knowing what you are.

## Reversal trigger

Re-open this ADR if: (a) the engine acquires a path that can determine posture
itself rather than receiving it — it should not; (b) HHS rulemaking changes what
the postures must enforce; (c) a partner integration requires DS4P conformance
testing beyond label passthrough; or (d) the product decides to ship the program
capability, which changes point 3's schedule but not points 1 or 2.

## References

- 42 CFR Part 2 as amended by the 2024 final rule (89 FR 12472)
- 45 CFR 164.520 as amended 26 Apr 2024 (89 FR 33064) — notice duty, compliance
  date 16 Feb 2026
- ADR 0001 (no Rails coupling), ADR 0002 (host-configurable policy)
- #291 (umbrella), #494 / #523 (record-level segmentation), #496 (scope minting
  — independent of posture), #522 (declared-posture enforcement), #532
  (disclosure-surface audit)
- rpms-ops#635, rpms-ops#536, rpms-rpc#224 (site configuration and live proof)
