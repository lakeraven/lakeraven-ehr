# ADR 0015: Assistive AI runs in a partner-controlled runtime behind one adapter

**Status:** Proposed
**Date:** 2026-11-16
**Issue:** #1136
**Builds on:** ADR 0005 (PHI access audit), ADR 0006 (Part 2 posture), ADR 0013 (a tenant is one RPMS instance)

## Context

Two products want model-generated suggestions. lakeraven-ehr would show a clinician a prompt
drawn from a registry (for example: this patient's last three blood pressures were above goal on
the current dose, consider titration). Corvid may suggest how to resolve an eligibility exception
for staff to confirm. Nothing in either product decides yet where a model runs, who can stop it,
what is recorded, or how a change to the model is checked.

The constraints are not technical preferences:

- **Patient data stays under the partner's control.** Tribal and urban partners own their data.
  A design that sends patient data to a hosted model the partner cannot inspect or stop is not
  acceptable to them, and we will not build one.
- **A clinician decides.** No suggestion prescribes, titrates, orders or writes to the chart on
  its own.
- **The partner can switch it off**, at any time, without asking us and without breaking the
  clinical workflow.
- **No vendor coupling.** Model serving is a commodity. Core logic (what a suggestion is, when it
  may be shown, what is logged) stays ours; the model and its server sit behind an adapter.

## Decision

1. **A separate component.** Assistive AI is its own component, not code inside lakeraven-ehr or
   Corvid. It is deployed per partner, on hardware or a cloud account the partner controls. Its
   repository is created when this ADR is accepted.

2. **One port, called by both products.** Each product calls a `Suggestions` port with a use-case
   id, a minimal input (the fields that use case needs, never the whole chart) and the requesting
   user. The port returns zero or more suggestions, each with its text, the inputs it relied on, and
   the model and prompt versions. The products never call a model SDK or a vendor API directly.

3. **The model is a pluggable adapter.** The default adapter talks to a locally served
   open-weight model over a standard inference HTTP interface, so the server software and the
   model can be swapped without changing the products. A hosted-model adapter may exist only for
   synthetic data in development.

4. **Every suggestion is logged in the partner's store.** The log records the use case, references
   to the inputs (not copies of them), model and prompt versions, the suggestion, who saw it, and
   whether it was accepted, edited or dismissed. Patient-level reads follow ADR 0005's audit rules.

5. **The off switch belongs to the partner and fails closed.** One switch per use case and one for
   the whole runtime, checked on every request. When it is off, or when the runtime cannot be
   reached, the products show no suggestion and the workflow continues exactly as it would without
   AI. Unreachable is treated as off, never as "show the last suggestion".

6. **No write-back without a clinician.** A suggestion is a draft. Anything it would change in a
   record goes through the product's normal write path, under the clinician's own identity and
   review. The runtime has no credentials to write to RPMS or any EHR.

7. **Part 2 data is withheld.** A use case does not receive data that ADR 0006 segments, unless a
   later ADR decides otherwise for that use case.

8. **A validation harness gates every change.** Each use case has a fixture set of synthetic
   inputs with expected outputs and a pass threshold. Any change to the model, its version, the
   prompt or the input mapping runs the harness on the partner's runtime before it is enabled,
   and the result is kept with the audit log.

## Consequences

### Positive
- Partners can verify where their data goes and can stop the feature themselves.
- Both products share one audited path instead of each growing its own.
- Changing model or server is an adapter change plus a harness run.

### Negative
- A small clinic needs hardware or a cloud account able to serve a small model, and someone to
  run it. Hosting options and their cost are not yet known.
- Small open-weight models are weaker than large hosted ones, so each use case needs evidence from
  the harness that it is good enough.
- One more component to deploy, version and support per partner.

### Alternatives considered
- **Build it into lakeraven-ehr.** Rejected: Corvid would need a second copy, and the off switch
  and audit log would follow EHR releases instead of the partner.
- **Call a hosted model API.** Rejected: patient data would leave the partner's control, and the
  partner could not stop or inspect it.
- **Put it in Corvid.** Rejected for the same reason as the EHR, and Corvid is not the clinical
  product.

## Build order (filed as sub-issues of #1136 once this is accepted)

1. The `Suggestions` port and a fake adapter, with the off switch and the fail-closed behaviour,
   in the new component.
2. The audit log and its read path.
3. The validation harness, with one synthetic fixture set.
4. The local-model adapter.
5. The lakeraven-ehr client for the port, showing suggestions read-only to a clinician.
6. The first use case (registry-based blood-pressure prompts), behind its own switch.

Slices 1 to 4 handle PHI and get the hard panel. Slice 5 onward touches the clinical UI and gets a
clinician-facing review as well.

## Open questions
- Which model sizes and hosting are realistic for a small clinic, and at what cost?
- What pass threshold does a use case need before it is switched on, and who signs it off?
- Does a partner that does not run RPMS (ADR 0013) reach the runtime through lakeraven-ehr at all,
  or only through Rook's Bulk FHIR feed?

## References
- #1136; ADR 0005, ADR 0006, ADR 0013
- Corvid ADR 0005 (adapter injection) for the adapter pattern
