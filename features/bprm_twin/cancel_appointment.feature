# BPRM twin — scenario #7: Cancel an appointment
# HTTP:  POST /appointments/:id/cancel
# RPC:   BSDX CANCEL APPOINTMENT  ->  APPDEL^BSDX08  ->  $$CANCEL^BSDAPI  ->  ^SC + ^BSDXAPPT
# BPRM:  BsdSetPatientAppointmentCancel
# Disposition: sql-mutate -> reimpl  (BPRM raw-deletes ^SC S-node; BSDAPI cancel is FileMan-safe)
@bprm_twin @scheduling
Feature: Cancel an appointment
  As a scheduling clerk
  I want to cancel a booked appointment with a reason
  So that the slot frees up and the cancellation is recorded

  Background:
    Given a registered patient with DFN 42
    And patient 42 has appointment 7001 in clinic 15 at "2026-08-20 09:00"

  Scenario: Clinic-cancel an appointment with a reason
    When I cancel appointment 7001 as "clinic" with reason "Provider unavailable" and note "Rescheduling"
    Then the cancellation succeeds
    And appointment 7001 is marked cancelled
    And the "2026-08-20 09:00" slot in clinic 15 is open again

  Scenario: Patient-cancel an appointment
    When I cancel appointment 7001 as "patient" with reason "Patient request"
    Then the cancellation succeeds
    And appointment 7001 is marked patient-cancelled

  Scenario: Cancelling an unknown appointment fails
    When I cancel appointment 999999 as "clinic" with reason "Provider unavailable"
    Then the cancellation is rejected with status 422
    And the error message mentions "Invalid Appointment ID"

  Scenario: Cancellation is blocked while another user holds the patient record
    Given another user holds a lock on patient 42's record
    When I cancel appointment 7001 as "clinic" with reason "Provider unavailable"
    Then the cancellation is rejected with status 409
    And the error message mentions "Another user is working with this patient"
