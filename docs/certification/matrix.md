# ONC §170.315 Certification Matrix

Single source of truth for the cert gauntlet (Epic #251). One row per criterion in
scope; phases per the 2026-07-25 decision: **Phase 1 = minimum viable CHPL listing**
(Base EHR definition + program conditions), **Phase 2 = full legacy-listing parity**.

**Mandatory-set basis** (verified 2026-07-26 against 45 CFR 170.102 / Part 170): the
Base EHR definition requires §170.315 (a)(1) or (2) or (3); (a)(5); (a)(14); (b)(1);
**(b)(11) — replaced (a)(9) on 2025-01-01 (HTI-1)**; (c)(1); (g)(7), (g)(9), (g)(10);
and **(h)(1) or (h)(2)**. Every listing additionally carries (g)(4) and (g)(5); (g)(3)
applies because SED-scoped a/b criteria are included; (b)(10) EHI export is a program
condition; the (d)-family privacy & security framework attaches per selected criteria.
Sources: [45 CFR 170.102](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-D/part-170/subpart-A/section-170.102),
[45 CFR Part 170](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-D/part-170),
[ONC g(10) API Resource Guide](https://onc-healthit.github.io/api-resource-guide/g10-criterion/).

Feature/step inventory audited 2026-07-25: every `features/onc/*.feature` has
substantive step definitions running in the default CI cucumber profile (no `@wip`).
"Spec gap" = no feature file exists yet. Legacy note: Epic #251's phase tables cite
**rpms_redux issue/PR numbers** (that repo's history); the issue numbers in THIS matrix
are lakeraven-ehr's. Some redux-era work needs restoration here (#367).

Evidence artifacts land under `evidence/<criterion>/` via the harness (#404); test
procedures (the per-criterion oracle) are the ONC CCG/test-procedure pages at
healthit.gov — each row's owner links the exact procedure when the work order starts.

## Phase 1 — minimum listing

| Criterion | What | Spec (scenarios) | Issues | Evidence / validator | Status |
|---|---|---|---|---|---|
| (a)(1) | CPOE medications | `onc/cpoe.feature` (10), `onc/cpoe_audit_trail.feature` (7) | — | procedure walkthrough + cucumber report | implemented |
| (a)(4)* | Drug-interaction checks | `drug_interactions.feature` (14) | — | procedure walkthrough | implemented (*SED-scoped elective, retained) |
| (a)(5) | Demographics | `onc/us_core_patient_api.feature` (8), `sdoh_sogi.feature` (6) | #360 (USCDI v3 audit) | USCDI v3 element checklist | implemented, audit open |
| (a)(14) | Implantable device list | `onc/implantable_device_list.feature` (10) | — | procedure walkthrough | implemented |
| (b)(1) | Transitions of care (C-CDA) | `onc/transitions_of_care.feature` (10), `care_coordination_interoperability.feature` (6) | #222 | **ETT / HL7 C-CDA validator** | implemented; Direct transport open (see h-row) |
| (b)(2)* | Clinical reconciliation | `onc/clinical_reconciliation.feature` (8) | #362 | ONC b-2 test-procedure run | implemented, procedure pass open (*elective, near-done) |
| (b)(10) | EHI export (condition) | `onc/ehi_export.feature` (9) | #229 | completeness manifest + format docs | implemented, docs open |
| (b)(11) | Decision support interventions (DSI) | `cds_rules.feature` (13), `onc/clinical_decision_support.feature` (19), `clinical_decision_support.feature` (4) | **#361** (HTI-1 source attributes) | DSI transparency artifacts | a-9-shaped today; **b-11 gap = #361** |
| (c)(1) | CQM record & export | `onc/cqm_record_and_export.feature` (7), `clinical_quality_measures.feature` (8) | #363, #365 (VSAC), #367 | **QRDA I/III validation** | repair queue open |
| (d)(1) | Auth / RBAC | `authentication.feature` (16), `mfa_authentication.feature`, `session_management.feature` | #358, **#401 (blocker)** | RBAC docs + config evidence | gaps open |
| (d)(2)(3) | Audit log + report | `phi_audit_logging.feature` (6), `fhir/audit_event.feature` (28) | — | audit report export | implemented |
| (d)(4) | Amendments | `onc/patient_amendments.feature` (8) | — | procedure walkthrough | implemented |
| (d)(5)(8)(12) | Timeout / integrity / credential encryption | partial coverage | — (redux gap table flagged; re-audit here) | config evidence | **verify** |
| (d)(6) | Emergency access | `onc/emergency_access.feature` (10) | — | procedure walkthrough | implemented |
| (d)(9) | Trusted connection | `encryption_verification.feature` | #359 | TLS attestation | open |
| (d)(11) | Accounting of disclosures | `onc/accounting_of_disclosures.feature` (8) | — | procedure walkthrough | implemented |
| (g)(3) | Safety-enhanced design | n/a (process) | **#402** | NISTIR 7742 report | study not run |
| (g)(4) | QMS | n/a (process) | **#403** | QMS narrative + attestation | not drafted |
| (g)(5) | Accessibility-centered design | `ui/accessibility.feature` (5) | — | WCAG audit + attestation | implemented |
| (g)(7)(9) | API: patient selection / all-data | FHIR surface + `bulk_export_download_auth.feature` (5) | #334, #254 | Inferno subtests | implemented, infra endpoints + search params open |
| (g)(10) | Standardized FHIR API | `onc/us_core_patient_api`, `onc/smart_ehr_launch` (3), `onc/backend_services_auth` (3), `fhir_smart_authentication` (8), `smart_launch_context` (6), `onc/provenance_revinclude` (2), `onc/vital_signs_compliance` (5) | **#261 (Inferno), #297, #360, #254** | **Inferno ONC suite report** | implemented, Inferno run = the gate |
| (h)(1) or (h)(2) | Direct messaging | **spec gap — no feature file** | **#226** | HISP interop evidence | **open decision: h-1 w/ HISP partner vs h-2 edge; then BDD-red spec first** |
| cross-cutting | Evidence harness | n/a | **#404** | `evidence/` bundle from CI | not built |
| external | ACB engagement / VSAC / FedRAMP hosting | n/a | #364 / #365 / #366 | contracts & licenses | calendar gates |
| terminal | ATL testing / CHPL listing | n/a | #259 / #260 | ACB results | after all above |

## Phase 2 — full parity

| Criterion | What | Spec (scenarios) | Issues | Validator | Status |
|---|---|---|---|---|---|
| (a)(15) | SDOH (Gravity IG) | `sdoh_sogi.feature` baseline | #153 | IG validation | partial |
| (b)(3) | e-Prescribing | `onc/electronic_prescribing.feature` (10) | **#405 (network cert — longest external pole)** | network certification scripts | code implemented |
| (b)(7)(8) | Security tags send/receive | **spec gap** | #223, #224 | C-CDA w/ confidentiality codes | BDD-red first |
| (e)(1) | View/Download/Transmit | `patient_portal_phr.feature` (16) + `patient_portal/` (33) | #225 | procedure walkthrough | partial |
| (f)(1) | Immunization registry (VXU) | `state_immunization_registry_exchange.feature` (11), `vfc_compliance` (8), `vaers_export` (4) | #230 | **NIST HL7v2 validator** | implemented, VXU open |
| (f)(2) | Syndromic surveillance | **spec gap** | #227 | NIST validator | BDD-red first |
| (f)(3) | Reportable labs (ORU) | `onc/electronic_lab_reporting.feature` (8) | #231 | NIST validator | implemented, ORU open |
| (f)(5) | Electronic case reporting | `onc/electronic_case_reporting.feature` (9) | #232 | eICR/RR validation | implemented |
| (f)(6) | Antimicrobial use/resistance | **spec gap** | #228 | NIST validator | BDD-red first |

Post-certification: #258 Real World Testing (annual condition).

## Parallel, non-blocking

YottaDB M-core fidelity (rpms-ops#283) and the workflow-spec conformance rig
(rpms-ops#149/#153): ONC certifies this module regardless of the RPMS backend; the
2026-07-25 portability census (26/197 packages touch IRIS constructs; P1 clinical
packages clean) means backend choice does not move any row above.
