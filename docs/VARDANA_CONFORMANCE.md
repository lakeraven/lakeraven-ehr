# Vardana source-system conformance — living checklist

Tracks lakeraven-ehr against the **Vardana Source System Profile v1** (September 2026)
§7 conformance checklist. Clinical-data items (3–10) are exercised by
`features/vardana_clinical_conformance.feature` (17 scenarios, tag
`@vardana_conformance`, enforced in CI); auth items (1–2) are owned by the parallel
auth workstream.

**Wire basis.** This surface is built on the VERIFIED reads in rpms-rpc PR #188
(branch `feat/provenance-phone-reads` — the Gemfile pins it; **merge sequences after
#188 lands**, then the pin moves back to main):

- `RpmsRpc::Measurement.history / .find` — ORQQVI VITALS index (verified
  `MEASUREMENT_IEN^TYPE^DATETIME^VALUE`, no units on that wire) decorated per
  measurement via `DDR GETS ENTRY DATA` on `#9000010.01` (type / patient / visit /
  value / ENTERED IN ERROR / event date-time), `BEHOENCX GETVISIT` (the visit's
  SERVICE CATEGORY, `#9000010` field `.07`) and `BEHOVM2 VUNITS` (source units).
- `RpmsRpc::Problem.for_patient` — verified ORQQPL LIST shape
  `IEN^NARRATIVE^STATUS^ICD^ONSET^LAST MODIFIED^…` (status `"A"`/`"I"`).
- `RpmsRpc::Patient.contact` — PATIENT `#2` fields `.131/.132/.134/.133` via the
  registered `DDR GETS ENTRY DATA`.

The prior revision of this PR was built on a FABRICATED `ORQQVI VITALS` shape
(`TYPE^VALUE^UNITS^DATE`); everything below has been rebuilt on the verified reads.

Statuses: **wire-proven** (BDD green over the real row shapes end-to-end through the
rpms-rpc parse, pending only the #188 merge), **engine-only** (engine behavior done,
wire cannot supply the signal — gap documented), **see auth PR**.

| # | Checklist item | Status | Evidence / honest notes |
|---|---|---|---|
| 1 | Backend services token obtained with a signed JWT assertion against a published JWKS | see auth PR | `feat/vardana-auth-conformance` (worktree `ehr-vardana-auth`) |
| 2 | Credential scoped to one organisation; cannot read another's patients | see auth PR | `feat/vardana-auth-conformance` |
| 3 | `GET /Patient/{id}` returns a patient with a usable telephone contact | **wire-proven** | Scenario "Patient read returns a usable telephone contact" seeds the actual DDR reply and exercises `RpmsRpc::Patient.contact` parsing through `PatientGateway` (residence → cell → work preference). |
| 4 | Active conditions and active medications return for that patient | **wire-proven** | Scenarios "Condition search filters to active problems and an inactive row stays inactive" / "MedicationRequest search filters to active medications". The old `:problem_list` mapping had STATUS/DESCRIPTION swapped, so a real inactive row mis-parsed and defaulted to "active" — fixed in rpms-rpc #188 + `test/models/lakeraven/ehr/condition_problem_wire_test.rb` pins the real inactive raw row. Unrecognized status codes now yield **no** clinicalStatus, never a guessed "active". |
| 5 | Observations return with LOINC codes, units, and clinical effective dates | **wire-proven** | LOINC via `Observation::VITAL_TYPE_MAP` (terminology mapping only). **Units come from the source** (`BEHOVM2 VUNITS`); a value without a source unit is DROPPED, not guessed (scenario "A value without a source unit is dropped, not guessed"). UCUM `code`/`system` are asserted only for units that translate to UCUM; otherwise the source unit rides as display text. `effectiveDateTime` is the clinical event date-time (`#9000010.01` field `1201`, `.07` fallback). |
| 6 | A blood pressure round-trips with both components and correct units | **wire-proven** | Components `8480-6`/`8462-4` in the source-supplied unit (mm[Hg]). A malformed BP value (e.g. "REFUSED") is dropped, never serialized as 0.0 components. |
| 7 | Pagination returns a complete set across more than one page | **wire-proven** | `_count` honoured on every searchset through the one shared `render_bundle` path (Patient search included); `Bundle.link` rel=self/next; `total` always the full match count; **`_count=0` returns total-only with zero entries** (FHIR R4 summary count). |
| 8 | Resource ids are stable across two reads separated by a data change | **wire-proven** | Ids are the real **V MEASUREMENT IEN** (`#9000010.01`) / problem IEN. Two same-minute readings of one type keep distinct ids; a row without an IEN is dropped rather than given a blank or colliding derived id. |
| 9 | A corrected value is distinguishable from the original | **wire-proven** (entered-in-error) | `Observation.status` derives from the wire ENTERED IN ERROR flag (`#9000010.01` field `2`, stored by `EIE^BEHOVM2`, read via DDR): true → `entered-in-error`, false → `final`, unreadable → `unknown` (never guessed). **Honest limit:** the wire carries no "amended" concept — a corrected replacement appears as a separate final measurement beside the entered-in-error original; `amended` status is NOT claimable from this wire. |
| 10 | Provenance, or an equivalent documented mechanism, distinguishes office-measured from patient-reported values | **wire-proven** (office vs not-office) | See mechanism below. **Honest limit:** the wire distinguishes office-measured from *not office-measured* (capture modality). It does NOT establish an informant, so "patient-reported" is never asserted — a non-office value is represented as unverified/not-office-measured with its modality. |

## Item 10 — the Provenance mechanism (documented)

**Where RPMS actually records the distinction.** A vital/measurement is a
**V MEASUREMENT** entry (file `9000010.01`, `^AUPNVMSR`); field `.03` points at its
**VISIT** (file `9000010`, `^AUPNVSIT`). The visit's **SERVICE CATEGORY** (field
`.07`) is PCC's record of the encounter's **capture modality**:

| Service category | Meaning | FHIR Provenance |
|---|---|---|
| `A` Ambulatory, `H` Hospitalization, `I` In Hospital, `O` Observation, `S` Day Surgery, `R` Nursing Home, `D` Daily Hospitalization Data | in-person clinical capture | `agent.type` = `author` (single CodeableConcept, per R4 0..1); `agent.who` = the recording provider's display name when the read supplies one, else a facility display — never an invented resource id |
| `T` Telecommunications, `M` Telemedicine, `E` Event (Historical), `C` Chart Review | **not office-measured** — the DD records the modality, NOT who supplied the value | no `agent.type` (the wire proves no participant role); `agent.who.display` = "Not office-measured — source modality: X; informant not recorded". **`who = Patient/{dfn}` is never asserted** — chart review / telemedicine says nothing about the patient being the informant |
| `N`, `X`, absent, anything else | unknown capture context | **no Provenance emitted** — Vardana treats a value without provenance as unverified (§3) |

Both classes carry `Provenance.activity` with the raw service-category code
(system `https://lakeraven.com/fhir/CodeSystem/rpms-visit-service-category`) so
machines get the wire-proven fact itself.

**R4 shape** (fixed from the prior revision): `agent.type` is a single
CodeableConcept (0..1 — was incorrectly an array); `recorded` is the instant the
provenance statement was derived by this server; the observation's clinical time is
`occurredDateTime`. Served at `GET /Provenance?patient={dfn}`,
`GET /Provenance?target=Observation/{measurement-ien}` (**no patient parameter
needed** — the by-IEN DDR read carries the patient in field `.02`), and
`GET /Provenance/prov-{measurement-ien}`.

## Certified-path containment

`app/controllers/lakeraven/ehr/charts_controller.rb` is byte-identical to `main`
except one call-site rename (`from_vital_hashes` → `from_measurement_hashes`); the
certified chart's own serialization logic is untouched. `render_bundle` changes are
additive (paging activates only when `_count`/`_page` are supplied; default
rendering is unchanged) and Patient search now goes through the same shared path.

## Known limits (engine honest-degrades, not gaps in this PR)

- `ORQQVI VITALS` history decoration is per-measurement (DDR/GETVISIT/VUNITS,
  memoized); when a sub-read is unreachable the row degrades to
  `capture_mode: :unknown` (no Provenance), `entered_in_error: nil`
  (status `unknown`) and `units: nil` (row dropped) — unknown is reported as
  unknown, never fabricated.
- `BEHOVM2 VUNITS` is keyed by the canonical AUTTMSR abbreviation; a type it
  cannot resolve yields no units and the value is dropped per §5.1.

## Out of scope this pass (noted follow-ups)

- **DiagnosticReport** (§4 `DiagnosticReport?patient=&date=ge{date}`) and
  **CarePlan** — models exist but are thin and not in the §7 checklist.
- Repoint the Gemfile's rpms-rpc pin from `feat/provenance-phone-reads` to main
  once rpms-rpc #188 merges (this PR merges after it).
