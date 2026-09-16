# ADR 0005: 42 CFR Part 2 posture — scope turns on one determination; segmentation is layered in the engine, never in RPMS

**Status:** Proposed — blocked on one product determination (see "The determination")
**Date:** 2026-09-15

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
  on the floor — which matters for Branch B below, because inbound documents
  from an outside SUD program arrive *already labeled* and we currently erase
  the label.
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
- Good Medicine: behavioral-health clinic (one therapist, mobile-first)
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

## The determination

**One question decides scope, cost, and schedule, and only the founder can
answer it: will the Good Medicine clinic *hold itself out as providing, and
provide, SUD diagnosis, treatment, or referral for treatment — or only
mental-health/behavioral-health services?***

Federal assistance is a given; the "program" prong is the whole test. Concrete
sub-questions that decide it (answer against the December service line, then
again for April):

1. Does the service list / website / community flyer mention substance use,
   addiction, recovery, MAT/MOUD, or SBIRT *as a service offered*?
2. Will any clinician prescribe buprenorphine/naltrexone *for* OUD/AUD, or
   run SUD counseling as a program?
3. Is "referral for treatment" part of the offering (an advertised SUD
   referral pathway is enough to satisfy "referral for treatment"), or do
   referrals happen only incidentally, the way an ER refers an overdose?

| | **A: Yes — SUD offered (Part 2 program)** | **B: No — MH/BH only (not a Part 2 program)** |
|---|---|---|
| **Regulatory posture** | Full Part 2: § 2.22 notice day one, § 2.31 consent capture, § 2.32 notices on egress, § 2.25 accounting (EHR-mediated TPO disclosures included), § 2.16 breach, OCR-enforced penalties — all already past their compliance date | HIPAA only for records we originate (§ 2.12(d)(2)(ii)); Part 2 duties attach **only to records received from outside Part 2 programs** (no legal-proceedings use ever; § 2.32 notice on redisclosure; no segregation required if received under single TPO consent) |
| **Build** | Record-level segmentation engine: SUD value-set classifier + sidecar labels, egress gating on *every* path (FHIR read/search, bulk export, C-CDA, chart UI), consent-on-file checks, Part 2 accounting wired, break-glass persisted, § 2.22 notice content, #494 + #496 closed as blockers | Inbound-document label preservation (stop dropping `confidentialityCode`/`meta.security` on C-CDA/FHIR ingest), quarantine-and-notice handling for received Part 2 records, § 2.32 notice passthrough on re-export, legal-hold/subpoena guard. No classifier, no egress gating of native records |
| **Cost (engineering)** | ~4–6 dev-months, and clinical-workflow cost forever after (suppressed meds/problems are a patient-safety trade the care team must govern) | ~2–4 dev-weeks |
| **December 2026** | **Not safely achievable.** Compliance date already passed; the clinic would be out of compliance on opening day under live OCR enforcement. Either the SUD service line waits (e.g., to April, aligned with primary care) or December slips | **Achievable.** BH-only launch needs the Branch B items, and only the inbound-records path is even exposed in a single-therapist December |
| **If we guess wrong** | Guessed A, truth B: 4–6 months spent; classifier shelved (labeling/consent/disclosure plumbing all reusable — see "no-regret" below); over-suppression friction until unwound | Guessed B, truth A: **operating a Part 2 program out of compliance from day one**, with unlabeled SUD data accumulating in RPMS that must be *retroactively* classified before any export/exchange path is safe — the expensive, maybe-impossible cleanup this ADR exists to prevent |

This document does not answer the question. It exists so that answering it is
a five-minute act with known consequences.

## Decision

**1. The determination above is surfaced to the founder as a decision, not a
ticket.** #291 is blocked on it and says so. No Part 2 implementation work
starts until it is answered in writing (an amendment to this ADR's Status
line), because the two branches diverge at the first commit.

**2. The architecture is decided now, whichever branch wins: Part 2
segmentation is enforced in the engine at the serialization/egress boundary,
expressed as DS4P security labels, and never delegated to RPMS.** RPMS cannot
represent it (headline finding); the engine's FHIR/C-CDA/export surface is
the only place every egress passes through. Concretely, when implementation
begins:

- A **classification service** (Branch A) or **inbound-label registry**
  (Branch B) produces, per record, a label set (`Confidentiality: R`,
  ActCode `SUD`/`OPIOIDUD`, DS4P handling codes incl. the § 2.32 obligation).
  Branch A classification is value-set-driven (ICD-10 F1x, SUD med RxNorm
  classes, LOINC tox panels, BH-package visit provenance), host-configurable,
  and stored in a local PG sidecar keyed to RPMS record identity — never
  written back into RPMS files.
- **Every egress path consults labels**: FHIR read/search (default scope
  excludes `R`-labeled records absent consent-on-file + authorized purpose),
  **bulk/EHI export** (labeled records withheld or included-with-labels per
  the export's consent basis — never silently included), **C-CDA**
  (`confidentialityCode` + DS4P section/entry tagging), chart UI.
- **Consent** is a first-class stored artifact implementing § 2.31's element
  list, including the single-TPO-consent form; egress decisions reference it;
  revocation stops future disclosure.
- **Every Part 2 egress writes a `Disclosure` row** — the existing
  `DisclosureService` finally gets production call sites — satisfying § 2.25
  including its EHR-mediated-TPO clause, and the § 2.32 notice is attached
  in-band (DS4P) and in generated documents.
- **Break-glass** (§ 2.12-consistent medical emergency) persists to PG with
  reason + after-the-fact review, extending `EmergencyAccessService`.
- **#496 closes before any of this is claimed to exist**, and #494 is the
  implementation marker for Branch A's engine.

**3. Deployment preconditions are stated, not assumed.** Because RPMS-side
access (roll-and-scroll, other RPC clients, printed health summaries) bypasses
the engine, a Branch A deployment requires site-level controls (RPMS account
and menu/key governance) documented as operational requirements. The engine's
conformance claims are scoped to its own surfaces.

**4. Tribal-data overlays are independent gates.** OCAP community
authorization is required for any SUD-touching aggregate/reporting flow in
either branch; Expert Determination remains the only acceptable
de-identification basis. Part 2 consent never substitutes for either.

## Consequences

### Positive

- The founder's decision is a five-minute fork with priced branches instead
  of an open-ended compliance anxiety.
- Branch B (if it holds) makes December safe with weeks, not months, of work
  — and the 2024 rule's no-segregation-under-TPO-consent clause
  (§ 2.12(d)(2)(i)(C)) means we are not building a shadow segmentation engine
  for records we merely receive.
- The label/consent/disclosure plumbing is no-regret: it is the same
  machinery ONC (d)(11) accounting and ordinary HIPAA hygiene want, so
  Branch-B-now does not strand work if April's primary-care launch later
  adds SUD services and flips us to Branch A.
- Putting the RPMS-can't-represent-it finding in the architecture (engine-
  boundary enforcement, PG sidecar) now prevents the dead-end alternative of
  waiting for a FileMan schema change that will never come.

### Negative

- Branch A's honest cost — months of work plus permanent clinical-workflow
  friction — may push the SUD service line out of December, a product
  decision this ADR forces into the open rather than resolving.
- Engine-boundary enforcement means we cannot claim deployment-wide
  compliance; RPMS-native access remains a documented residual risk managed
  operationally.
- A computed classifier (Branch A) will have false negatives at the margins
  (free-text notes referencing SUD, meds with dual indications); the design
  accepts label-at-egress plus curated value sets rather than promising
  perfection, and says so in conformance language.

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

Re-open this ADR if: (a) the determination's answer changes (a service-line
addition in April that adds SUD treatment flips B→A with a hard compliance
date of the service's first day); (b) HHS issues the anticipated further
alignment rulemaking (the 2024 preamble flags follow-on work, and 45 CFR
164.520 NPP changes interlock); or (c) a partner integration requires DS4P
conformance testing beyond label passthrough.

## References

- Issue #291 (this ADR's marker — blocked on the determination)
- Issue #494 (record-level segmentation — Branch A implementation marker)
- Issue #496 (unverified backend-services JWT — blocker for any Part 2 claim)
- ADR 0001 (authorization library). Note: #291 cites "ADR 0002" for a
  host-configurable tagging rule and "ADR 0003"; this repo's ADR 0002/0003
  are staff-UI placement and ETL archival — the issue's ADR and model
  references (`Case`/`Determination`/`Task`) belong to another repo's set
  and do not apply here.
- 42 CFR Part 2, current text: https://www.ecfr.gov/current/title-42/chapter-I/subchapter-A/part-2
  (definitions § 2.11; applicability & federal-assistance test § 2.12;
  safeguards § 2.13; security & breach § 2.16; notice § 2.22; intermediary
  list § 2.24; accounting § 2.25; consent § 2.31; redisclosure notice § 2.32;
  TPO redisclosure § 2.33; penalties § 2.3)
- Final rule: "Confidentiality of Substance Use Disorder (SUD) Patient
  Records," 89 FR 12472 (Feb. 16, 2024):
  https://www.federalregister.gov/documents/2024/02/16/2024-02544/confidentiality-of-substance-use-disorder-sud-patient-records
- HHS fact sheet on the final rule:
  https://www.hhs.gov/hipaa/for-professionals/regulatory-initiatives/fact-sheet-42-cfr-part-2-final-rule/index.html
- Compliance date / enforcement commencement (Feb 16, 2026):
  https://www.hipaajournal.com/february-16-2026-compliance-deadline-part-2-final-rule/ ;
  https://www.quarles.com/newsroom/publications/go-for-gold-42-cfr-part-2-compliance-deadline-and-hhs-enforcement-is-here
- 42 U.S.C. 290dd-2 (statute, as amended by CARES Act § 3221)
- HL7 FHIR Data Segmentation for Privacy (DS4P) IG, STU1:
  https://hl7.org/fhir/uv/security-label-ds4p/STU1/
- FHIR R4 security labels: https://hl7.org/fhir/R4/security-labels.html
- HL7 v3 ActCode (SUD/OPIOIDUD sensitivity) and Confidentiality (R):
  https://terminology.hl7.org/CodeSystem-v3-ActCode.html ;
  https://terminology.hl7.org/CodeSystem-v3-Confidentiality.html
