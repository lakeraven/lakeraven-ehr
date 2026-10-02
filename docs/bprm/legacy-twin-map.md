# Legacy BPRM twin features, mapped to rpms-ux scenarios

The 16 feature files directly under `features/bprm_twin/` (61 scenarios) were written
from BPRM 4.0's stored procedures (`docs/BPRM_REG_SCHED_TWIN.md`) before the rpms-ux
story set existed, so they assert at the HTTP/JSON level and carry no scenario id.
This map gives each one the rpms-ux scenario it proves (lakeraven-ehr#571), as the
`@S-XXX-NN.N` tag on the scenario, or says why it has none.

Rules applied: a legacy scenario takes an id only when its user action and its asserted
outcome are the ones that scenario's Then describes, even if it asserts fewer of the
Then's conjuncts (the gap is in the reason column). One id per scenario, the most
specific one. The seven ids the driven features own (`w01_registration/`,
`w02_scheduling/`: S-REG-01.1, S-REG-01.2, S-REG-02.1, S-REG-02.2, S-SCH-01.1,
S-SCH-01.3, S-SCH-01.4, and S-REG-02.8 which was claimed while this map was made) were
not available; the driven set grows, so re-run `bin/bprm_coverage --check` after merging. A tagged id leaves
`features/bprm_twin/stubs/` the next time `bin/bprm_stubs` runs.

Counts: 28 tagged, 17 untagged with a proposed new rpms-ux scenario, 10 untagged
because an existing scenario already describes them (duplicate of a driven scenario,
a subset of a stub, or a conflict to settle), 6 harness (`parity.feature`).

## Map

| File | Scenario | rpms-ux id | Reason |
|---|---|---|---|
| adt_movement.feature | Admit a patient | S-ADT-01.1 | Admit with date/time, ward and provider; patient on the ward's census. Type, source, specialty and diagnosis are not asserted. |
| adt_movement.feature | Transfer a patient to another ward | S-ADT-02.1 | Transfer with date/time; patient on the new ward. |
| adt_movement.feature | Discharge a patient | S-ADT-03.1 | Discharge with date/time and disposition; patient off the census. |
| adt_movement.feature | Cancel an erroneous movement | S-ADT-04.1 | Cancel the admission movement; census corrected. The reason is not asserted. |
| adt_movement.feature | Admitting an already-admitted patient is rejected | S-ADT-01.5 | Added to rpms-ux from this scenario (rpms-ux 0397622). |
| adt_movement.feature | Discharging a patient who is not admitted is rejected | S-ADT-03.4 | Added to rpms-ux from this scenario (rpms-ux 0397622). |
| adt_movement.feature | Admitting to an unknown or closed ward is rejected | S-ADT-01.6 | Added to rpms-ux from this scenario (rpms-ux 0397622); S-ADT-01.2 is a missing value, not an invalid ward. |
| adt_movement.feature | Re-admission shortly after discharge surfaces the re-admit check | S-ADT-01.7 | Added to rpms-ux from this scenario (rpms-ux 0397622); BPRM's `BdgGetIsReAdmitCheck` warning. |
| appointment_availability.feature | List open slots for a day | S-SCH-04.1 | Slots inside the block are returned and the booked one is not. One day, not a range; the display start hour is not asserted. |
| appointment_availability.feature | List configured access blocks | none | A subset of S-SCH-05.2 (block with type and span) reached through a config read, not by viewing a day; the stub keeps the holiday half. |
| appointment_availability.feature | A day with no access blocks has no open slots | none | A corollary of S-SCH-04.1's "every slot returned starts inside one of those blocks". |
| availability_config.feature | Set a recurring availability block | none | Clinic setup, which the W02 preamble defers to a site-setup workflow; proposal below. |
| availability_config.feature | Add a clinic holiday | none | Site setup (HOLIDAY #40.5); the read side is S-SCH-04.3; proposal below. |
| availability_config.feature | Remove a clinic holiday | none | Site setup; proposal below. |
| book_appointment.feature | Book an open slot | none | The same action and outcome as S-SCH-01.1, which `w02_scheduling/book_appointment.feature` owns; this is its HTTP half. |
| book_appointment.feature | Double-booking an occupied slot is rejected | S-SCH-01.2 | A full slot is refused as not available. The overbook-key arm is not asserted. |
| book_appointment.feature | Booking on an unknown clinic fails | S-SCH-01.14 | Added to rpms-ux from this scenario (rpms-ux 0397622); S-SCH-01.7 is an inactive clinic, not one that is not on file. |
| book_appointment.feature | Booking a patient with an overlapping appointment warns | none | Conflicts with S-SCH-01.5 (same date and time is refused): BPRM warns and files; see the ambiguities and the proposal below. |
| cancel_appointment.feature | Clinic-cancel an appointment with a reason | S-SCH-02.7 | Cancel on the clinic's behalf with reason and remarks; marked cancelled, slot free. |
| cancel_appointment.feature | Patient-cancel an appointment | none | S-SCH-02.1 exactly, which `w02_scheduling/cancel_appointment.feature` owns; this is its HTTP half. |
| cancel_appointment.feature | Cancelling an unknown appointment fails | S-SCH-02.14 | Added to rpms-ux from this scenario (rpms-ux 0397622). |
| cancel_appointment.feature | Cancellation is blocked while another user holds the patient record | S-SCH-02.15 | Added to rpms-ux from this scenario (rpms-ux 0397622); the FileMan lock. |
| checkin_appointment.feature | Check a patient in at arrival | S-SCH-03.1 | Check in; appointment checked in. The visit is not asserted. |
| checkin_appointment.feature | Undo a check-in | S-SCH-03.9 | Undo; appointment scheduled again. |
| checkin_appointment.feature | Cannot check in a cancelled appointment | S-SCH-03.7 | Only the cancelled arm of the four. |
| clinic_schedule.feature | View the clinic schedule for a date | S-SCH-05.3 | The day's appointments in time order with each status. Overbook marking is not asserted. S-SCH-13.3 (the printed report) was the alternative. |
| clinic_schedule.feature | Cancelled appointments are excluded by default | none | Conflicts with S-SCH-05.3, where cancelled appointments show with their status; see the ambiguities. |
| clinic_schedule.feature | Include cancelled appointments when requested | none | The cancelled arm of S-SCH-05.3; the first scenario of the file is the better claim on that id. |
| edit_patient_demographics.feature | Correct a misspelled patient name | S-REG-20.10 | Added to rpms-ux from this scenario (rpms-ux 0397622): a spelling correction, not S-REG-26.1's legal name change with proof. |
| edit_patient_demographics.feature | Update a patient's cell phone number | S-REG-21.5 | Change the cell phone; PATIENT (#2) holds it. The other phones and email are not asserted. |
| edit_patient_demographics.feature | Record a date of death | S-REG-27.1 | Record the date of death; patient marked deceased. State, certificate and cause are not asserted, and the legacy persona is a clerk. |
| edit_patient_demographics.feature | Set the Medicare Beneficiary Identifier | none | The identifier alone, set from the demographics page; S-BEN-02.1 records the whole Medicare entitlement and its stub keeps that. |
| no_show_appointment.feature | Flag a no-show after the appointment time | S-SCH-08.1 | Mark a no-show after the time; status no-show. Remarks are not asserted. |
| no_show_appointment.feature | Undo a no-show | S-SCH-08.4 | Undo; appointment scheduled again. |
| no_show_appointment.feature | Cannot no-show a future appointment | S-SCH-08.2 | Only the time-not-passed arm. |
| parity.feature | A registration is identical on YDB and IRIS backends (outline) | none | Harness, see below. |
| parity.feature | The YDB and IRIS registrations are byte-identical after normalization | none | Harness. |
| parity.feature | Registering a new patient matches the BPRM BMW-SQL golden | none | Harness. |
| parity.feature | Booking an appointment matches the BPRM BMW-SQL golden | none | Harness. |
| parity.feature | An admission matches the BPRM BMW-SQL golden at the validated layer | none | Harness. |
| parity.feature | A missing required field is rejected identically by both paths | none | Harness. |
| patient_appointments.feature | List future appointments | S-SCH-05.6 | The patient's appointments listed with their clinic. Division, type, maker and check-in details are not asserted; the legacy filters to future ones. |
| patient_appointments.feature | List cancelled appointments | none | The cancelled arm of S-SCH-05.6, already claimed by the scenario above. |
| patient_appointments.feature | Generate a routing slip for a day's visit | S-SCH-13.7 | The routing slip for that patient, with name and health record number. Only the routing-slip arm of the five printouts. |
| patient_eligibility_insurance.feature | List a patient's insurances | S-BEN-01.1 | Both coverages listed with their insurer and number. Dates are not asserted; the in-use flag has no rpms-ux counterpart. |
| patient_eligibility_insurance.feature | Update a policy number | S-BEN-01.3 | Added to rpms-ux from this scenario (rpms-ux 0397622). |
| patient_eligibility_insurance.feature | Delete an insurance and cascade its dependent records safely | S-BEN-01.4 | Added to rpms-ux from this scenario (rpms-ux 0397622); S-BEN-04.3 and S-BEN-02.6 remove one member or part. |
| patient_eligibility_insurance.feature | Deleting an in-use insurance is blocked | S-BEN-04.4 | Coverage that claims use is not deleted and the user is told. rpms-ux words it as a warning; the API refuses. |
| patient_lookup.feature | Search by partial last name | none | The HTTP half of S-REG-01.1 (owned by `w01_registration/find_patient.feature`) without the date of birth. |
| patient_lookup.feature | Search by date of birth narrows the match | none | S-REG-01.1 exactly, which the driven feature owns. |
| patient_lookup.feature | Retrieve the face sheet for a patient | S-REG-24.2 | The face sheet carries the registration as filed. Index card and wrist band are not asserted. |
| patient_lookup.feature | Face sheet surfaces registration errors and warnings | S-REG-23.1 | A missing item is listed against the patient. Section grouping and the error/warning counts are not asserted. |
| patient_lookup.feature | Lookup of an unknown DFN returns not found | S-REG-01.7 | Added to rpms-ux from this scenario (rpms-ux 0397622). |
| rebook_appointment.feature | Rebook to a new open slot | S-SCH-02.8 | Move with a reason; old slot free, new appointment at the new time. The rescheduled remark and the carried note are not asserted. |
| rebook_appointment.feature | If the new slot is unavailable the original appointment is preserved | S-SCH-02.10 | The move is refused and the original stays booked. |
| register_patient.feature | Register a new American Indian/Alaska Native patient | S-REG-02.14 | A complete registration raises the registration event (BPRM's `AgPatientRegisterEvent`). Date established and the establishing user are not asserted; S-REG-02.1 is owned by the driven feature. |
| register_patient.feature | Reject a duplicate SSN | none | S-REG-02.8 exactly, but the driven `w01_registration/` feature claimed that id while this map was made; this is its HTTP half. |
| register_patient.feature | Broker unreachable surfaces as service-unavailable, not a data error | S-REG-02.16 | Added to rpms-ux from this scenario (rpms-ux 0397622); cross-cutting, written once under S-REG-02. |
| register_patient.feature | Incomplete registration returns warnings but still creates the chart | none | Conflicts with S-REG-02.2 (a missing community is refused); see the ambiguities. |
| waiting_list.feature | Add a patient to the waiting list | S-SCH-10.1 | Add with reason and priority; the clinic's list holds the patient. Provider, recall date and comments are not asserted. |
| waiting_list.feature | Report the waiting list | S-SCH-13.6 | The clinic's wait list report lists its entries. Ranges, grouping and the summary form are not asserted. |

## Behaviours with no rpms-ux scenario

Status after rpms-ux `0397622`: twelve of the proposals below are now scenarios in rpms-ux (S-REG-01.7, S-REG-02.16, S-REG-20.10, S-SCH-01.14, S-SCH-02.14, S-SCH-02.15, S-ADT-01.5, S-ADT-01.6, S-ADT-01.7, S-ADT-03.4, S-BEN-01.3, S-BEN-01.4) and the legacy scenarios above carry those tags.
Not added, for the analyst (rpms-ux#3): S-SCH-01.15 (an overlapping appointment warns, which contradicts S-SCH-01.5) and the S-SCH-14 site-setup story, which the W02 preamble defers.

Proposed in the rpms-ux style (Then as FileMan state or the refusal). Each names the
story to append to; the number is the story's next free one.

### W18 ADT (`adt_movement.feature`)

Append to S-ADT-01 Admit a patient:

- S-ADT-01.5: Given a patient who is already a current inpatient, When I admit them again,
  Then it is refused and PATIENT MOVEMENT (#405) holds only the one open admission.
- S-ADT-01.6: Given a ward that is not in WARD LOCATION (#42), or one out of service on the
  admission date, When I save the admission, Then it is refused and names the ward, and no
  movement is filed.
- S-ADT-01.7: Given a patient discharged within the facility's re-admission window, When I
  admit them, Then the admission is filed and I am warned of the previous discharge with its
  date.

Append to S-ADT-03 Discharge a patient:

- S-ADT-03.4: Given a patient who is not a current inpatient, When I discharge them, Then it
  is refused and no movement is filed.

### W02 Scheduling

Append to S-SCH-01 Book an appointment (`book_appointment.feature`):

- S-SCH-01.14: Given a clinic that is not in HOSPITAL LOCATION (#44), When I book, Then it
  is refused and names the clinic, and nothing is filed. (API-level: a screen cannot offer
  a clinic that is not on file; keep only if the API contract is a story.)
- S-SCH-01.15: Given the patient has an active appointment whose time overlaps the chosen
  slot without starting at the same time, When I book, Then I am warned of the other
  appointment and the appointment is filed. (Pending the S-SCH-01.5 decision below.)

Append to S-SCH-02 Cancel or reschedule (`cancel_appointment.feature`):

- S-SCH-02.14: Given an appointment that is not on the clinic in HOSPITAL LOCATION
  (#44.003) nor on the patient in PATIENT (#2.98), When I cancel it, Then it is refused and
  nothing is filed. (API-level, as S-SCH-01.14.)
- S-SCH-02.15: Given another user is editing the patient's appointments (the lock on the
  patient's PATIENT (#2.98) entry is held), When I cancel one, Then it is refused, I am told
  another user is working with this patient, and the appointment stays booked. (Applies to
  every scheduling write; S-SCH-02 is where the legacy asserts it.)

New story, site setup (`availability_config.feature`): the W02 preamble leaves clinics,
access types and holidays to a site-setup workflow that rpms-ux has not written. Proposed
as S-SCH-14 Set up a clinic's availability, persona site_manager:

- S-SCH-14.1: Given a clinic's resource in BSDX RESOURCE (#9002018.1), When I set its
  availability for each weekday from a start to an end hour with a slot length and an access
  type, Then BSDX ACCESS BLOCK (#9002018.3) holds one block per day in that span with that
  type and slot count, and a search for open slots (S-SCH-04.1) returns slots inside them.
- S-SCH-14.2: Given a date the clinic does not work, When I add it as a holiday, Then
  HOLIDAY (#40.5) holds it and a search for open slots returns none on it for a clinic that
  does not schedule on holidays (S-SCH-04.3).
- S-SCH-14.3: Given a holiday on file, When I remove it, Then HOLIDAY (#40.5) no longer
  holds it and the clinic's slots on that date are returned again.

### W01 Registration

Append to S-REG-20 Keep the patient's demographics current
(`edit_patient_demographics.feature`):

- S-REG-20.10: Given a patient whose name was misspelled at registration, When I correct
  the spelling, Then PATIENT (#2) holds the corrected name, the audit of IHS PATIENT
  (#9000001) holds the change with me and today, and PATIENT NAME CHANGES (#9000033) is
  unchanged. (See the ambiguity on whether BPRM's `AgSetCorrectPatientName` is instead the
  S-REG-26.1 path.)

Append to S-REG-01 Find the patient before registering (`patient_lookup.feature`):

- S-REG-01.7: Given a patient identifier that is not in PATIENT (#2), When I open it, Then
  I am told there is no such patient and no record opens. (API-level; a screen reaches a
  patient only from a search result.)

Append to S-REG-02 Register a new patient (`register_patient.feature`):

- S-REG-02.16: Given RPMS cannot be reached, When I save a registration, Then I am told the
  registration service is unavailable, nothing is filed, and my entries are kept so I can try
  again. (Cross-cutting: the same holds for every write in W01, W02, W18 and W19; rpms-ux
  may prefer it once, as a workflow-wide rule, rather than per story.)

### W19 Benefits (`patient_eligibility_insurance.feature`)

Append to S-BEN-01 See all of a patient's coverage:

- S-BEN-01.3: Given coverage on file, When I correct its policy or beneficiary number, Then
  the file that holds that coverage (MEDICAID ELIGIBLE (#9000004), PRIVATE INSURANCE
  ELIGIBLE (#9000006), MEDICARE ELIGIBLE (#9000003)) holds the corrected number and its
  eligibility dates are unchanged.
- S-BEN-01.4: Given coverage on file that no claim has been billed to, When I delete it,
  Then that coverage file no longer holds it, the patient's other coverage is unchanged,
  and no cross-reference or dependent entry that pointed at it remains.

## Harness, not a story

`parity.feature` (6 scenarios, one an outline): engine-vs-engine (YDB against IRIS) and
path parity (lakeraven-ehr's RPC write against BPRM's BMW-SQL write, read back through
FileMan and compared to a golden), per `docs/BPRM_PARITY_PLAN.md`. It proves that two
implementations leave the same state, not that a user can do something; no rpms-ux story
should carry it. Left untagged, and it should stay out of `bin/bprm_coverage --strict`
by an exemption for `@parity`, or move out of `features/bprm_twin/`.

## Ambiguities to settle

- S-SCH-01.5 vs BPRM: rpms-ux refuses a booking at the same date and time as an active
  appointment; `book_appointment.feature` has BPRM filing an overlapping (not identical)
  time with a warning. Both can be true; the proposal S-SCH-01.15 keeps them apart, but
  someone should check what BPRM does for an identical time.
- S-SCH-05.3 vs BPRM: rpms-ux shows cancelled appointments on the day with their status;
  `clinic_schedule.feature` hides them unless asked. If BPRM's grid has such a toggle,
  S-SCH-05.3 should say so.
- S-REG-02.2 vs BPRM: rpms-ux refuses a registration with no community;
  `register_patient.feature` has BPRM (AG) filing it and listing COMMUNITY as an incomplete
  item (S-REG-23.1's errors-and-warnings). Which is right decides whether S-REG-02.1/02.2
  and S-REG-02.13 keep community as a required field. Until then the legacy scenario is
  untagged and contradicts the driven S-REG-02.2.
- `AgSetCorrectPatientName`: tagged nothing. If it is BPRM's legal name change (proof,
  document number, PATIENT NAME CHANGES #9000033), the legacy "Correct a misspelled
  patient name" belongs to S-REG-26.1 and the S-REG-20.10 proposal is unneeded.
- S-BEN-04.4 is tagged on a refusal though rpms-ux words it as a warning before deletion;
  if the warning is meant to be confirmable, the legacy assertion is too strict.
- Partial proofs: several tags (S-ADT-01.1, S-SCH-03.1, S-SCH-05.6, S-SCH-13.7,
  S-SCH-13.6, S-REG-02.14, S-REG-27.1) assert fewer conjuncts than the Then; the reason
  column says which. The tag removes the stub, so the unasserted conjuncts are now covered
  only by the legacy scenario's eventual step definitions.
