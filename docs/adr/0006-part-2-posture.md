# ADR 0006: RPMS cannot express record-level sensitivity, so segmentation is layered in the engine

**Status:** Proposed
**Date:** 2026-09-15 · **Reduced to scope:** 2026-09-23

> **Renumbered.** Drafted as ADR 0005; `0005` is *PHI access audit* on `main`.

## Scope, and what this ADR deliberately is not

This ADR makes **one architectural finding** and draws its consequence. It does
not interpret 42 CFR Part 2, does not determine whether any deployment is a
Part 2 program, and does not price or schedule compliance work.

Earlier drafts did all three. Two successive adversarial regulatory reviews
blocked them, and the second found the replacement worse than the original: a
posture contract in which the only declaration the engine would serve was
"not a program", which pressures an operator toward the convenient answer.
The reviews were right, and the lesson is narrower than it looks — **regulatory
interpretation does not belong in an engineering ADR written without counsel.**

So the regulatory summary, the program/non-program contract, the cost tables and
the deployment-posture decision are all removed. What remains is the part that
survived every review untouched, because it is a fact about the datastore rather
than a reading of a regulation.

**Where the removed material belongs:**

| Question | Owner |
|---|---|
| Is a given deployment a Part 2 program? | that organisation, with counsel — recorded with its deploy configuration, off-git |
| What obligations follow, and on whom (including this vendor's own status where it operates the host) | counsel |
| What the engine must therefore enforce, and when | a follow-on ADR written **after** those answers exist |

Nothing in this document should be cited as a compliance position.

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


### What exists in this engine today

- **Access audit**: `app/controllers/concerns/lakeraven/ehr/auditable_clinical_access.rb`
  writes one immutable `AuditEvent` row per FHIR request (local PG). No
  purpose-of-use, no recipient concept; write failures are swallowed.
- **Accounting of disclosures**: `app/services/lakeraven/ehr/disclosure_service.rb`
  + `Disclosure` model (recipient, purpose, `consent_reference`, 6-year
  retention, ONC (d)(11) / 45 CFR 164.528 shaped). **No production call
  site** — nothing in the FHIR, export, or C-CDA paths records a disclosure.
  The machinery exists; it is plumbing without pipes.
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
  engine; never persists PHI. Architecturally it sits on the far side of an
  **egress boundary**: anything this engine's FHIR API serves corvid has left
  this engine's control. Corvid's own outbound artifacts (claims, referral
  packets) are a further egress from there. Nothing persists corvid-side, so no
  corvid schema change is forced by labelling work here. What obligations
  attach at either boundary is a compliance question, not settled here.


## Decision

**Any record-level sensitivity segmentation this engine supports is enforced in
the engine, at the serialization/egress boundary, and is never delegated to
RPMS.** Labels live in a local PG sidecar keyed to RPMS record identity and are
never written back into RPMS files.

This follows from the headline finding alone. RPMS has no per-record sensitivity
field on the shared clinical files, so there is no store-side mechanism to
delegate to, and no FileMan schema change is coming that would create one.
Waiting for one is the dead end this decision exists to rule out.

**Two consequences of that are stated now because they constrain any later
design, whatever the compliance answer turns out to be:**

1. **The engine's egress boundary is the only enforcement point it has.** All
   clinical models are RPC-backed `ActiveModel` facades; there is no database
   scope to lean on. Every egress path — FHIR read/search, bulk export, C-CDA,
   the chart UI — must consult the same labels, or the control is decorative.
2. **The engine cannot make a deployment compliant, only its own surfaces.**
   Direct RPMS roll-and-scroll, other RPC clients, health summaries printed at
   the facility, and the PCC visit that billed an encounter all bypass this
   engine entirely. Any claim about a deployment's overall posture depends on
   site-level controls — RPMS account, menu and security-key governance — that
   are outside this engine's reach. Whether the RPMS behavioural-health
   package's separation is actually configured on a given instance is site
   configuration plus a live-dispatch proof, never an assumption
   (rpms-ops#635, rpms-ops#536, rpms-rpc#224).

## Consequences

### Positive

- The dead-end alternative — waiting for RPMS to gain a per-record sensitivity
  field — is ruled out on evidence rather than left as an open option.
- The enforcement point is named before any labelling work starts, so a later
  design cannot quietly put the control somewhere that half the egress paths
  bypass.
- The document no longer asserts anything it has no standing to assert, which
  is why it can be merged while the compliance questions are still open.

### Negative

- This ADR now answers less than its title once promised. The questions it used
  to answer are real and still open; they are simply not answerable here.
- Saying "the engine cannot make a deployment compliant" is accurate and
  unsatisfying: it leaves the residual risk with operational controls that no
  code review can verify.

### Alternatives considered

- **Delegate segmentation to RPMS.** Rejected on the headline finding: the
  shared clinical files have no per-record sensitivity attribute, and the
  patient-level flag and BH-package screening are the wrong granularity and the
  wrong scope respectively.
- **Enforce at each consumer instead of at the engine boundary.** Rejected: it
  multiplies the control surface by the number of consumers and fails the first
  time a new consumer forgets.
- **Keep the regulatory analysis here with a disclaimer.** Rejected — tried,
  reviewed, blocked. A disclaimer naming two known errors does not make the
  remaining text safe to cite, and load-bearing conclusions were resting on the
  incomplete parts.

## Reversal trigger

Re-open if: (a) RPMS gains a per-record sensitivity attribute on the shared
clinical files; (b) counsel's answers arrive and a follow-on ADR needs this one
amended rather than extended; or (c) a partner integration requires DS4P
conformance beyond label passthrough.

## References

- ADR 0001 (no Rails coupling), ADR 0002 (host-configurable policy)
- #291 (umbrella), #494 / #523 (record-level segmentation), #522 (posture
  enforcement), #532 (disclosure-surface audit — engine egress inventory)
- rpms-ops#635, rpms-ops#536, rpms-rpc#224 (site configuration and live proof)
- `rpms-rpc/lib/rpms_rpc/mappings/stock_vista.rb:660` (`ORWPT SELCHK`),
  `$$GUIPL^AMHUTIL` (BH package screening)
