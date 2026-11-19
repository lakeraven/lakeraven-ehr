# ADR 0017: Publish the governance shapes as an open FHIR implementation guide, and take it to HL7

**Status:** Proposed
**Date:** 2026-11-19
**Relates to:** ADR 0016 (Indigenous data governance invariants)
**Decides:** that the wire shapes ADR 0016 needs are published as an open, vendor-neutral FHIR
implementation guide (IG), reviewed by Indigenous governance bodies, and offered to HL7. It does not
write the profiles.

## Context

FHIR already covers part of ADR 0016 well, and the products should use it as is:

| Need | Existing FHIR |
|---|---|
| Race, ethnicity, tribal affiliation | US Core race, ethnicity and `us-core-tribal-affiliation` extensions |
| Stratified measure results | `MeasureReport.group.stratifier` |
| Access and release audit | `AuditEvent`, `Provenance` |
| Population export | Bulk Data (`$export`) |

It has gaps exactly where ADR 0016 is new:

- **Collective authority.** `Consent` is about one person. `Contract` is general and little used.
  `Permission` (R5 and later) is closer but young. None models a governing body, its authority type
  (sovereign nation, steward, public health authority), or an approval that a body can revoke.
- **Data agreements.** No profile ties a release to a recorded agreement with recipient, purpose,
  elements, de-identification level and expiry.
- **Suppression.** `MeasureReport` has no standard way to say a cell was suppressed, by whose policy,
  rather than being zero or absent.
- **Hold before release.** Nothing marks a report as held for community review, or records when the
  community saw it and when an outside recipient did.
- **Method of collection.** US Core race and ethnicity cannot say whether a value was self-identified or
  observer-reported.
- **IHS beneficiary class.** GPRA counts AI/AN patients by beneficiary class, not race. Rook already reads
  a Lakeraven extension for it (`https://terminology.lakeraven.com/StructureDefinition/ihs-beneficiary-class`),
  which no other system can send unless the profile is published.
- **Return of data to nations.** No exchange pattern exists. This IG names it as future work only.

Lakeraven keeps core logic in house and puts commodity functions behind adapters. A wire format is not
core logic; it is more useful the more parties share it. If the shapes stay private, each tribe, UIO and
TEC that uses another vendor is left out, which is the opposite of what ADR 0016 is for.

## Decision

1. **An open IG.** Lakeraven authors an IG, working title *Indigenous Data Governance*, on FHIR R4 (to
   match US Core), published with an open license from a public repository. Version 0.1 covers:
   - **Governing body**: an `Organization` profile with an authority-type extension (tribal nation, UIO,
     TEC, other) and the body's role.
   - **Governance approval and data agreement**: a profile that records approver, decision, scope
     (recipient, purpose, data elements, de-identification level), period and revocation. The IG authors
     choose between `Permission` (via cross-version extensions on R4), `Contract` and `Consent`, and write
     down why.
   - **Suppression label**: an extension on `MeasureReport` strata and populations that marks a value
     as suppressed and references the policy that suppressed it.
   - **Release hold**: how a `MeasureReport` (or the bundle that carries it) is marked held for community
     review, and the `AuditEvent` pattern that records community release and external release.
   - **Race and ethnicity collection method**: an extension that says how each race and ethnicity was
     collected.
   - **IHS beneficiary class**: a `Patient` extension and its code system, published so any EHR can send
     it. IHS owns the meaning of beneficiary class; the IG references it and does not redefine it.
2. **Governance review before anything is submitted.** A tribal data governance board and a UIO advisory
   council review the IG's scope and draft before it goes to HL7 or a connectathon. Their comments and how
   each was resolved are kept with the IG. The IG names no customer and no partner.
3. **A path into HL7.** In order, each step gated on the one before:
   1. Bring the draft to the HL7 work groups whose resources it profiles, as candidates to sponsor:
      Community-Based Care and Privacy (Consent, Permission), Security (AuditEvent, Provenance, labels),
      Clinical Quality Information (MeasureReport), and Public Health. The US Realm Steering Committee
      reviews a US-realm IG.
   2. Propose a connectathon track that exercises the approval check, labeled suppression and the
      beneficiary-class extension between at least two independent systems.
   3. With a sponsoring work group, file a project proposal and take the IG to ballot as a
      Standard for Trial Use, or publish it through the FHIR community process if HL7 sponsorship is not
      the right home.
   4. Ask the US Core maintainers to consider the collection-method extension for a later US Core release.
4. **Products use the IG's shapes.** Lakeraven EHR, Rook and Corvid emit and read the IG's profiles. Until a
   profile is published, they use the Lakeraven-namespaced URL the IG will publish under, so nothing has
   to change twice.

## Consequences

- Rook's beneficiary-class extension and the EHR's collection-method extension get a published definition,
  so other EHRs can send them and validators can check them.
- Profile work happens in the open. Profiles carry no PHI and use synthetic examples only.
- HL7 timelines are long (ballot cycles run months). Products do not wait for ballot: they build against
  the draft and follow it as it changes.
- A public repository for the IG and HL7 membership or participation are owner decisions and spend, not
  factory work.
