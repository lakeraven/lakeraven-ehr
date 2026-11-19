# ADR 0016: A customer's governing body controls collection, use and release of its data

**Status:** Proposed
**Date:** 2026-11-19
**Applies to:** Lakeraven EHR, Rook, Corvid (and the Aviary egress gate)
**Decides:** the invariants every product follows for Indigenous data governance. It does not choose a data model, a store, or a UI.

## Context

Lakeraven's customers are tribal nations, urban Indian organizations (UIOs) and the tribal epidemiology
centers (TECs) that serve them. Each holds data about AI/AN people, and each has a different kind of
authority over it:

- A **tribal nation** is sovereign. Its governing body (council, data governance board, research review
  board) can refuse any use of its data, and the refusal binds.
- A **UIO** is a steward. It governs through community governance such as a board or an advisory council,
  but the people in its records are citizens of many nations. Its policies bind its own releases. They do
  not make it the owner.
- A **TEC** is a public health authority for a region. It receives data under agreement. It is not an owner.

The CARE Principles for Indigenous Data Governance (Collective benefit, Authority to control,
Responsibility, Ethics) and, in Canada, OCAP® describe what these bodies expect. They sit on top of HIPAA
and 42 CFR Part 2 and do not replace them.

What exists today is partial:

- Lakeraven EHR records individual disclosures (`DisclosureService`), applies FHIR redaction views
  (`external`, `research`), holds an individual FHIR Consent model, and audits PHI access (ADR 0005). None
  of these checks a collective agreement.
- Corvid's governed migration (`Corvid::GovernedMigration`, `Migration::TribalConsentGate`) refuses a
  transfer without data governance board consent, but the consent is an in-memory value, not a stored,
  revocable record.
- Rook computes measures and renders reports but has no release step, no stratifiers and no small-count
  handling.
- Aviary's design puts a tribal-side egress gate in front of any population-level use and treats a
  nation's authorization as a credential separate from a person's consent.

Without shared rules, each product will invent its own notion of "approved", and a UIO will be modeled as
if it were sovereign, or a nation as if it were merely a data controller.

## Decision

Every product follows these invariants. Each is testable.

1. **Three authority types.** A tenant declares its authority type (tribal nation, UIO, TEC, other) at
   onboarding. The type sets which defaults apply. The product never treats a UIO as sovereign or a tribal
   nation as a steward.
2. **The governing body is a first-class actor.** A tenant names the body or bodies that govern its data,
   their members and roles, and which decision types need their approval. One decision type may need more
   than one body.
3. **Approvals are records.** An approval names the approving body, the decision, its scope (recipient,
   purpose, data elements, de-identification level), when it starts, when it expires, and whether it was
   revoked. It is checked when the action runs, not only when it is configured.
4. **Collective and individual consent are both required, and neither overrides the other.** A patient's
   consent does not authorize a collective use the governing body refused. A governing body's approval
   does not override a patient's refusal.
5. **Deny by default.** No data leaves a tenant's control unless an active approval covers that path.
   No approval, an expired or revoked one, or a failed lookup all mean no release. The product records
   which: *refused* (an approval exists and says no, or was revoked) or *could not determine* (nothing on
   file, or the check failed). Absence of a record is never approval.
6. **Revocation stops the next transfer.** Revoking an approval takes effect on the next run of every path
   it covered. It does not claim to recall data already released.
7. **Results go to the community first.** Any outbound report passes a hold with a named reviewer before
   release. The audit shows when the community saw it and when the external recipient did.
8. **No asterisk.** Inside a tenant's own view, counts are never suppressed. On external release,
   suppression happens only by the governing body's policy, and a suppressed cell says which policy
   suppressed it. AI/AN alone and AI/AN in combination are never folded into "other" or "multiracial".
9. **Identity is self-identified and kept whole.** Race, ethnicity and tribal affiliation are
   self-identified, can hold more than one value, carry how they were collected, and are never inferred.
   IHS beneficiary class is separate from race.
10. **No secondary use without approval.** Tenant data is not pooled across tenants, used to train or
    evaluate models, or used for vendor benchmarking unless the governing body approves under rule 3. Any
    AI feature that processes tenant data names the model, where it runs, and who approved it (ADR 0015).
11. **One contract, many products.** EHR, Rook and Corvid check approvals through one shared contract (a
    port), so a revocation in one place stops every product. Where the approvals are stored is the
    tenant's choice and is behind an adapter, consistent with Aviary's tribal-side egress check.

## What this ADR does not do

- Interpret tribal codes, IRB rules or state Indigenous data sovereignty policies. The customer's counsel
  and governing body own that.
- Draft data agreements. The product records and enforces them.
- Set any customer's policy. Defaults are conservative; the governing body sets the rest.

## Consequences

- Every egress path in every product (FHIR APIs used by outside parties, exports, report submissions,
  migrations, TEC feeds) gains a check against an approval, and each needs a failing test that proves
  deny-by-default before it ships.
- Corvid's in-memory `BoardConsent` becomes a read of a stored approval.
- Rook gains stratifiers, labeled suppression and a hold-before-release step before any real report
  submission.
- The shapes these records take on the wire are proposed as an open FHIR implementation guide (ADR 0017),
  so that other vendors and nations can use the same shapes.
- Build order: identity defects first (bugs in shipped code), then stored approvals, then Rook
  stratification and hold-before-release, then release agreements and the TEC feed. Community-defined
  measures, collection governance, return of data to nations, the transparency report and the
  secondary-use rule follow after a tribal data governance board and a UIO advisory council have reviewed
  the design.

## Open questions

1. Who approves releases in a UIO: the board, an advisory council, or both? (Rule 2 allows several.)
2. What small-count rule applies to an external release when the governing body has not set one?
