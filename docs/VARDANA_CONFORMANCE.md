# Vardana source-system conformance — living checklist

Tracks lakeraven-ehr against the **Vardana Source System Profile v1** (September 2026)
§7 conformance checklist. Clinical-data items (3–10) are exercised by
`features/vardana_clinical_conformance.feature`; auth items (1–2) are owned by the
parallel auth workstream.

Statuses: **done** (BDD green on the engine surface), **partial** (engine surface done,
RPMS wire plumbing gap documented below), **see auth PR**.

| # | Checklist item | Status | Evidence / scenario |
|---|---|---|---|
| 1 | Backend services token obtained with a signed JWT assertion against a published JWKS | see auth PR | `feat/vardana-auth-conformance` (worktree `ehr-vardana-auth`) |
| 2 | Credential scoped to one organisation; cannot read another's patients | see auth PR | `feat/vardana-auth-conformance` |
| 3 | `GET /Patient/{id}` returns a patient with a usable telephone contact | **partial** | Scenario "Patient read returns a usable telephone contact". `FHIR::PatientSerializer#build_telecoms` emits `telecom[{system: phone}]` whenever the hydrated patient carries a phone. **Wire gap:** RPMS stores the number in PATIENT file `#2`, field `.131 PHONE NUMBER [RESIDENCE]` (`^DPT(DFN,.13)` piece 1 — see `DGRRPSAM.m`), but no read RPC in the rpms-rpc corpus returns it (`ORWPT SELECT` / `ORWPT ID INFO` verified phone-free); follow-up filed in rpms-rpc |
| 4 | Active conditions and active medications return for that patient | **done** | Scenarios "Condition search filters to active problems" / "MedicationRequest search filters to active medications". `Condition?patient=&clinical-status=active` and `MedicationRequest?patient=&status=active` filter server-side; ORQQPL LIST status `A/I` → FHIR `active/inactive`, RPMS pharmacy `DISCONTINUED` → `stopped` (never a raw pass-through) |
| 5 | Observations return with LOINC codes, units, and clinical effective dates | **done** | Scenario "Observations return with LOINC codes, units, and clinical effective dates". LOINC via `Observation::VITAL_TYPE_MAP`; `valueQuantity` = numeric value + UCUM unit + `http://unitsofmeasure.org`; `effectiveDateTime` is the **clinical** date: ORQQVI VITALS piece 4 carries the measurement date — V MEASUREMENT (file `9000010.01`) field `1201 EVENT DATE AND TIME` ("Date/Time Vitals Taken", BJPC patch bjpc0200.04), falling back to the parent VISIT date (`LAST^BGOVMSR`: `DAT=+$G(^AUPNVMSR(IEN,12))`, else `+$G(^AUPNVSIT(VSIT,0))`) — never an import/entry date |
| 6 | A blood pressure round-trips with both components and correct units | **done** | Scenario "A blood pressure round-trips with both components and correct units": components `8480-6` and `8462-4`, each `valueQuantity` in `mm[Hg]` with UCUM system |
| 7 | Pagination returns a complete set across more than one page | **done** | Scenario "Pagination returns a complete set across more than one page". `_count` honoured on every searchset; `Bundle.link` rel=self/next; `total` is always the full match count; page walk reassembles the complete, duplicate-free set |
| 8 | Resource ids are stable across two reads separated by a data change | **done** | Scenario "Resource ids are stable across two reads separated by a data change". Ids are the RPMS IEN where the RPC supplies one, else deterministically derived (`vital-{dfn}-{type}-{timestamp}`, `appt-{dfn}-{timestamp}`, `problem-{dfn}-{code}`) — never random |
| 9 | A corrected value is distinguishable from the original | **done** | Scenario "A corrected value is distinguishable from the original". `Observation.status` honours a gateway-supplied status (`entered-in-error`, `amended`, …) and only falls back to `final` when none is supplied. **RPMS grounding:** V MEASUREMENT carries `ENTERED IN ERROR` + `REASON ENTERED IN ERROR` (added by BJPC patch bjpc0200.04; entered-in-error measurements are suppressed from RPMS reports). **Wire gap:** ORQQVI VITALS does not return the flag — see below |
| 10 | Provenance, or an equivalent documented mechanism, distinguishes office-measured from patient-reported values | **done** (engine) / **partial** (wire) | Scenarios "Office-measured and phone-reported values are distinguishable via Provenance", "Provenance is searchable by target observation", "A value whose capture context is unknown yields no Provenance". See mechanism below |

## Item 10 — the Provenance mechanism (documented)

**Where RPMS actually records the distinction.** A vital/measurement is a
**V MEASUREMENT** entry (file `9000010.01`, global `^AUPNVMSR`); node-0 piece 3 points
at its **VISIT** (file `9000010`, `^AUPNVSIT`). The visit's **SERVICE CATEGORY**
(field `.07`, node-0 piece 7; decoded from `^DD(9000010,.07)` — see `SCAT^AZAXCADU`)
is PCC's own record of how the encounter's data was captured:

| Service category | Meaning | FHIR Provenance agent |
|---|---|---|
| `A` Ambulatory, `H` Hospitalization, `I` In Hospital, `O` Observation, `S` Day Surgery | in-person clinical capture | `agent.type` = `author`; `agent.who` = `Practitioner/{DUZ}` when the entered-by user (V MEASUREMENT node-12 piece 4) is available, else a display-only facility reference |
| `T` Telecommunications, `M` Telemedicine, `E` Event (Historical), `C` Chart Review | reported, not measured in the office | `agent.type` = `informant`; `agent.who` = `Patient/{dfn}` |
| absent / anything else | unknown capture context | **no Provenance emitted** — Vardana treats a value without provenance as unverified (§3), which is the honest representation |

Serialized as US Core-shaped `Provenance` (`target` → the Observation, `recorded`,
`agent`) by `FHIR::ObservationProvenanceSerializer`; served at
`GET /Provenance?patient={dfn}` and `GET /Provenance?target=Observation/{id}`
(plus `GET /Provenance/prov-{observation-id}`), with ids deterministic
(`prov-{observation-id}`) so they are stable across reads.

## Known wire gaps (engine done, RPC plumbing follow-up)

The vitals read path is `ORQQVI VITALS`, whose response is
`TYPE^VALUE^UNITS^DATE` (rpms-rpc `mappings/stock_vista.rb`, `:vitals`). It carries
**no visit pointer, no service category, no entered-in-error flag, no entered-by DUZ**.
The engine accepts `service_category` / `visit_ien` / `provider_duz` / `status` keys on
gateway rows and serves correct FHIR from them (BDD-verified at the gateway seam); a
PCC-aware read in rpms-rpc (e.g. composing the V-file walk `^AUPNVMSR` →
`^AUPNVSIT` service category, as `LAST^BGOVMSR` does) is the follow-up that lights
these fields up end-to-end. Until then, live observations carry no service category and
therefore yield no Provenance — degrading exactly as §3 prescribes (values treated as
unverified), never mislabelling.

Patient telephone is the same shape: serializer ready, no phone-bearing read RPC yet
(PATIENT file `#2` field `.131`).

## Out of scope this pass (noted follow-ups)

- **DiagnosticReport** (§4 `DiagnosticReport?patient=&date=ge{date}`) and **CarePlan**
  — models exist but are thin and not in the §7 checklist; wire-up is a follow-up.
- rpms-rpc: PCC measurement read exposing visit service category / entered-in-error /
  entered-by; patient demographics read exposing `.131` phone.
