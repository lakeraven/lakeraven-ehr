# BPRM Registration + Scheduling — Executable-Spec Twin

Behavioral spec ("digital twin") for RPMS **BPRM v4** (IHS Practice Management):
patient **registration** and appointment **scheduling**. The goal is to let
`lakeraven-ehr` reimplement BPRM's user-facing behavior over the **VistA RPC
broker** (via the `rpms_rpc` Ruby client) instead of BPRM's IRIS-coupled
Blazor/BMW-SQL client.

We are **not** porting the BPRM client. We are capturing *what it does* as
Given/When/Then scenarios plus a Rails HTTP contract, and re-grounding each
scenario on an **engine-portable** RPC (BSDX scheduling / AG registration /
FileMan `^DIE`/DBS) rather than BPRM's IRIS-SQL stored procedures.

## Why the re-grounding is safe (and better)

BPRM's server tier is `BMW.BSF.SP.*` stored procedures over the InterSystems
SQL wire (see `rpms-ops/docs/BMW_BPRM_CORNER.md`). Its methods fall in four
buckets:

| BPRM SP bucket | Count | This twin's disposition |
|---|---|---|
| READ-ONLY SPs | 38 | Re-express as broker reads (BSDX BMX-query / AG / `$$GET1^DIQ`). No behavior change. |
| FILEMAN-WRITE SPs | 32 | Already delegate to standard M APIs (`^DIE`, `BDGAPI`, `BSDAPI`, `DGPMV*`). Re-ground on the same APIs via the broker — 1:1. |
| **SQL-MUTATE SPs** | **21** | **fix-the-audit-gap.** Raw `INSERT/UPDATE/DELETE` on `^DGPM`/`^DPT`/`^SC`/`^AUPN*` that bypass FileMan cross-refs + audit. Reimplement as proper FileMan writes (`^DIE`/DBS) or the equivalent IHS API. The IRIS versions leave a data-integrity defect we do **not** preserve. |
| Views | 31 | Read projections; re-expressed as broker reads / `rpms_rpc` mappings. |

Total: **91 SP + 31 VW = 122 classes / 171 `SqlProc` methods.**

The scheduling write path we target already exists and is API-mediated:
**BSDX** (Clinical Scheduling for Windows, namespace `BSDX`, ~64 routines) is a
BMX-broker/RPC package, engine-portable. Its four named write RPCs delegate to
the IHS scheduling API `BSDAPI`, which updates `^SC` and `^BSDXAPPT` through
proper entry points:

- `BSDX ADD APPOINTMENT`     → `$$ADD^BSDAPI`   (verified in `BSDX08.m` family)
- `BSDX CANCEL APPOINTMENT`  → `APPDEL^BSDX08` → `$$CANCEL^BSDAPI`
- `BSDX CHECKIN APPOINTMENT` → check-in via `BSDAPI` / `^DGPM` check-in node
- `BSDX NOSHOW APPOINTMENT`  → no-show via `BSDAPI`

BSDX **reads** (available slots, clinic schedule, a patient's appointments) go
through the BMX generic-query RPC against the BSDX files
(`9002018.4 BSDX APPOINTMENT`, `9002018.3 BSDX ACCESS BLOCK`, …) and `^SC`.

Registration re-grounds on the **AG** (IHS Patient Registration) package and
`BHDPTRPC` (already wired in `rpms_rpc`: `BHDPTRPC REGISTER`, `NEWVISIT`, `SU`,
`TRIBAL`, `TRIBALELG`) plus FileMan `^DPT` (PATIENT #2) / `^AUPNPAT`.

## Concrete RPC/file oracle (source of truth for the mapping)

- Registration: `rpms_rpc` `RpmsRpc::Patient` (`BHDPTRPC REGISTER` etc.), AG package, `^DPT`/`^AUPNPAT`.
- Scheduling writes: `BSDX ADD/CANCEL/CHECKIN/NOSHOW APPOINTMENT` → `BSDAPI` → `^SC` + `^BSDXAPPT` (9002018.4).
- Scheduling reads: BMX query over `^SC`, `BSDX APPOINTMENT` (9002018.4), `BSDX ACCESS BLOCK` (9002018.3); `ORWPT APPTLST` for a patient's appt list.
- ADT movements: `DGPMV*` / `^DIE` on `^DGPM` (INPATIENT MOVEMENT #405).

## Scenario → HTTP → RPC/FileMan mapping (master table)

Column key for **Disposition**: `read` = read-only re-express · `fm-write` =
already-FileMan-safe API · **`sql-mutate→reimpl`** = one of the 21 audit-gap
procs, reimplement as a proper FileMan/API write.

| # | Feature file | Scenario group | HTTP | Underlying RPC / FileMan | BPRM SP(s) subsumed | Disposition |
|---|---|---|---|---|---|---|
| 1 | `register_patient.feature` | Register a new patient | `POST /patients` | `BHDPTRPC REGISTER` → AG → `^DPT`/`^AUPNPAT` | `AgPatientRegisterEvent` | **sql-mutate→reimpl** |
| 2 | `edit_patient_demographics.feature` | Edit demographics | `PATCH /patients/:dfn` | `BHDPTRPC` update / AG → `^DIE` on `^DPT` | `AgPatientUpdateEvent`, `AgSetCorrectPatientName`, `AgSetPatientCellNumber`, `AgSetPatientDateOfDeath`, `AgSetPatientMbi` (set) | **sql-mutate→reimpl** |
| 3 | `patient_eligibility_insurance.feature` | View/edit eligibility + insurance | `GET/PATCH/DELETE /patients/:dfn/insurances` | AG insurance API → `^DIE` on `^AUPNPAT`/insurance files; read via BMX | `BsdGetPatientInsurances`, `AgGetPatientInsuranceInUse` (read); `AgSetPatientInsuranceDelete` (7-table dynamic delete) | read + **sql-mutate→reimpl** |
| 4 | `patient_lookup.feature` | Search / face sheet | `GET /patients?q=` , `GET /patients/:dfn` | `BHDPTRPC`/`patient_select` + BMX search | `AgSearchPatient`, `AgGetPatientSearchResult`, `AgGetPatientFaceSheet`, `AgGetPatientErrorsAndWarnings`, `AgGetPatientMbi` (get) | read |
| 5 | `book_appointment.feature` | Book an appointment | `POST /clinics/:ien/appointments` | `BSDX ADD APPOINTMENT` → `$$ADD^BSDAPI` → `^SC`+`^BSDXAPPT` | `BsdSetPatientAppointment`, `BsdSetPatientAppointmentV4` | **sql-mutate→reimpl** |
| 6 | `appointment_availability.feature` | Available slots / access blocks | `GET /clinics/:ien/availability` | BMX query on `BSDX ACCESS BLOCK` (9002018.3) + `^SC` | `BsdGetSchedulingAvailableSlots`, `BsdGetSchedulingAccessBlocks`, `BsdGetSchedulingConfigAccessBlocks` | read |
| 7 | `cancel_appointment.feature` | Cancel an appointment | `POST /appointments/:id/cancel` | `BSDX CANCEL APPOINTMENT` → `$$CANCEL^BSDAPI` | `BsdSetPatientAppointmentCancel` | **sql-mutate→reimpl** |
| 8 | `no_show_appointment.feature` | Mark no-show | `POST /appointments/:id/no_show` | `BSDX NOSHOW APPOINTMENT` → `BSDAPI` | (BPRM had no dedicated SP; BSDX-native) | fm-write |
| 9 | `checkin_appointment.feature` | Check-in / undo check-in | `POST /appointments/:id/check_in`, `.../undo_check_in` | `BSDX CHECKIN APPOINTMENT` → `BSDAPI`/`^DGPM` | `BsdSetPatientAppointmentCheckIn(V4)`, `BsdSetPatientAppointmentUndoCheckIn(V4)` | **sql-mutate→reimpl** |
| 10 | `rebook_appointment.feature` | Cancel + rebook (composite) | orchestrates #7 then #5 | cancel then add via `BSDAPI` | (composite of `BsdSetPatientAppointmentCancel` + `BsdSetPatientAppointment`) | **sql-mutate→reimpl** |
| 11 | `clinic_schedule.feature` | List a clinic's day | `GET /clinics/:ien/schedule?date=` | BMX query on `^SC`/`BSDX APPOINTMENT`; `BsdReportClinicSchedule` | `BsdReportClinicSchedule`, `BsdClinicScheduleReport`, `BsdGetSched*` (12E2/764F/8FC9 triplets) | read |
| 12 | `patient_appointments.feature` | A patient's future appts / routing slip | `GET /patients/:dfn/appointments`, `.../routing_slip` | `ORWPT APPTLST` + BMX; `BsdRoutingSlip` | `BsdGetPatientFutureApptsReport`, `BsdReportPatientFutureAppts`, `BsdRoutingSlip`, `BsdReportRoutingSlip`, `BsdReportCancelledAppointment` | read |
| 13 | `waiting_list.feature` | Waiting list add/report | `GET/POST /clinics/:ien/waiting_list` | `BSDWL*` API on wait-list file; report via BMX | `BsdReportWaitingList`, `BsdSetPatie*` (waitlist set triplets) | read + **sql-mutate→reimpl** |
| 14 | `availability_config.feature` | Availability config / holidays | `PUT /clinics/:ien/availability_config`, `POST/DELETE .../holidays` | `BSDAPI`/`^DIE` on `BSDX ACCESS BLOCK`/`ACCESS TYPE` | `BsdSetAvailabilityConfig`, `BsdSetSchedulingAddHoliday`, `BsdSetSchedulingRemoveHoliday`, `BsdSetSched*` (6175/D9B7 triplets) | **sql-mutate→reimpl** |
| 15 | `adt_movement.feature` | Admit / transfer / discharge / cancel movement | `POST /patients/:dfn/movements`, `PATCH/DELETE /movements/:id` | `DGPMV*` / `^DIE` on `^DGPM` (405) | `BdgSetPatientAdmission(V4)`, `BdgSetPatientMovement(Edit/CancelV4)`, `BdgSetPatientMovementDischarge(V4)`, `BdgSetPatientTransfer(V4)`, `BdgSetPatientSpecialtyTransfer(V4)`, `BdgCancelMovement` | **sql-mutate→reimpl** |
| — | (reports, read) | ADT census / benefit / insurance reports | `GET /reports/*` | BMX read views | `BdgGetAdsReport`, `BdgGetRangeOfMonthCensus`, `BdgGetIsReAdmitCheck`, `AgBenefitCasesReport`, `AgInsuranceCoverageReport`, `AgReport*`, `AgGetIncompleteChartStatistics*`, `AgGetPatientWellnessHandout` | read |

## Coverage / counts

- **BPRM `SqlProc` logical methods mapped: all 91 SP classes** are accounted for
  across scenarios #1–#15 + the reports row (the hash-suffixed `*D/*I/*S`
  triplets are IRIS query-metadata siblings of a base method, not separate
  behavior). The 31 `VW` views are subsumed by the read scenarios (#3, #4, #6,
  #11, #12) that project the same data through the broker.
- **Left as "needs the 21 sql-mutate reimplementation":** the **21** SQL-MUTATE
  SPs, concentrated in scheduling (`Bsd*` book/cancel/check-in/config) and ADT
  (`Bdg*` movements) plus the registration/demographics writes (`Ag*` register,
  update, insurance-delete). These are flagged **sql-mutate→reimpl** in the
  table (scenarios #1, #2, #3, #5, #7, #9, #10, #13, #14, #15) and must be
  implemented as proper FileMan/`^DIE`/DBS or IHS-API writes — never as raw
  global sets — so cross-references and audit fire. `AgSetPatientInsuranceDelete`
  (the dynamic-SQL 7-table cascade delete, scenario #3) is the highest-risk item.

## HTTP contract conventions

- JSON in/out, `Content-Type: application/json`. Patient identity is `dfn`
  (FileMan IEN of `^DPT`). Appointment identity is the `BSDX APPOINTMENT` IEN.
- FileMan dates are ISO-8601 at the HTTP edge; the gateway converts to FileMan
  internal form (`rpms_rpc` `FilemanDateParser`), matching the existing
  `RpmsRpc::Patient.registration_param` (`NAME^SEX^DOB^SSN`) convention.
- Write endpoints return the created/updated resource plus a `warnings[]` array
  carrying RPMS errors-and-warnings (e.g. incomplete registration items), so the
  UI can surface them the way BPRM's face sheet does.
- Failures distinguish **rejection** (`4xx`, M-side message in `error`) from
  **broker-unreachable** (`503`, `"…service unavailable"`), mirroring the
  existing `PatientGateway.register` contract.

## Step definitions

These `.feature` files are the spec; step definitions live under
`features/step_definitions/bprm_twin_steps.rb` (a stub is included that pends
each step so the suite is runnable-but-red until the gateways land — red→green
as the factory implements each scenario).
