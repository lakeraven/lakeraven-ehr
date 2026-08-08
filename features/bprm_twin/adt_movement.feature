# BPRM twin — scenario #15: Inpatient ADT movements (admit / transfer / discharge)
# HTTP:  POST /patients/:dfn/movements        (admit)
#        PATCH /movements/:id                 (edit)
#        POST /movements/:id/discharge
#        POST /patients/:dfn/movements/transfer
#        DELETE /movements/:id                (cancel movement)
# RPC:   DGPMV* / ^DIE on ^DGPM (INPATIENT MOVEMENT #405)
# BPRM:  BdgSetPatientAdmission(V4), BdgSetPatientMovement(Edit/CancelV4),
#        BdgSetPatientMovementDischarge(V4), BdgSetPatientTransfer(V4),
#        BdgSetPatientSpecialtyTransfer(V4), BdgCancelMovement;
#        re-admit guard: BdgGetIsReAdmitCheck
# Disposition: sql-mutate -> reimpl  (BPRM raw-writes ^DGPM bypassing movement xrefs; use DGPMV*/^DIE)
@bprm_twin @adt
Feature: Inpatient admission, transfer, and discharge (ADT)
  As an ADT/registration clerk at a facility with inpatient beds
  I want to admit, move, and discharge patients
  So that the inpatient census and movement history stay correct

  Background:
    Given a registered patient with DFN 42 named "RAVEN,NORA"
    And an inpatient ward "MED/SURG" with IEN 3

  Scenario: Admit a patient
    When I admit patient 42 to ward 3 at "2026-08-20 14:00" under provider "BEGAY,MICHELLE"
    Then the admission succeeds
    And patient 42 appears on the census for ward 3
    And the movement is written through DGPMV* (not a raw ^DGPM set)

  Scenario: Transfer a patient to another ward
    Given patient 42 is admitted to ward 3
    And an inpatient ward "ICU" with IEN 4
    When I transfer patient 42 to ward 4 at "2026-08-21 08:00"
    Then the transfer succeeds
    And patient 42 appears on the census for ward 4

  Scenario: Discharge a patient
    Given patient 42 is admitted to ward 3
    When I discharge patient 42 at "2026-08-23 11:00" with disposition "Home"
    Then the discharge succeeds
    And patient 42 no longer appears on the census for ward 3

  Scenario: Cancel an erroneous movement
    Given patient 42 has movement 8001 admitting to ward 3
    When I cancel movement 8001
    Then the cancellation succeeds
    And the census for ward 3 is corrected

  Scenario: Admitting an already-admitted patient is rejected
    Given patient 42 is admitted to ward 3
    When I admit patient 42 to ward 3 at "2026-08-21 09:00" under provider "BEGAY,MICHELLE"
    Then the admission is rejected with status 409
    And the error message mentions "already admitted"
    And patient 42 still has exactly one open admission

  Scenario: Discharging a patient who is not admitted is rejected
    When I discharge patient 42 at "2026-08-23 11:00" with disposition "Home"
    Then the discharge is rejected with status 422
    And the error message mentions "not currently admitted"

  Scenario: Admitting to an unknown or closed ward is rejected
    Given ward 99 does not exist or is closed
    When I admit patient 42 to ward 99 at "2026-08-20 14:00" under provider "BEGAY,MICHELLE"
    Then the admission is rejected with status 422
    And the error message mentions "ward"
    And no movement is created for patient 42

  Scenario: Re-admission shortly after discharge surfaces the re-admit check
    Given patient 42 was discharged from ward 3 on "2026-08-18"
    When I admit patient 42 to ward 3 at "2026-08-20 14:00" under provider "BEGAY,MICHELLE"
    Then the admission succeeds
    And the response warnings include a re-admission notice referencing the "2026-08-18" discharge
