# BPRM twin — scenario #9: Check-in / undo check-in
# HTTP:  POST /appointments/:id/check_in   POST /appointments/:id/undo_check_in
# RPC:   BSDX CHECKIN APPOINTMENT  ->  CHECKIN^BSDX25  ->  BSDAPI  ->  ^DGPM check-in + ^SC status
# BPRM:  BsdSetPatientAppointmentCheckIn, BsdSetPatientAppointmentCheckInV4,
#        BsdSetPatientAppointmentUndoCheckIn, BsdSetPatientAppointmentUndoCheckInV4
# Disposition: sql-mutate -> reimpl  (BPRM raw-writes ^DGPM/^SC; reimplement via BSDAPI/^DIE)
@bprm_twin @scheduling
Feature: Check in a patient for their appointment
  As a front-desk clerk
  I want to check a patient in when they arrive
  So that the provider's clinic list shows them present and a visit begins

  Background:
    Given a registered patient with DFN 42
    And patient 42 has appointment 7001 in clinic 15 at "2026-08-20 09:00"

  Scenario: Check a patient in at arrival
    Given the current time is "2026-08-20 08:55"
    When I check in appointment 7001
    Then the check-in succeeds
    And appointment 7001 status is "checked-in"
    And a check-in movement is recorded through BSDAPI (not a raw ^DGPM set)

  Scenario: Undo a check-in
    Given appointment 7001 is checked in
    When I undo the check-in on appointment 7001
    Then appointment 7001 status is "scheduled"

  Scenario: Cannot check in a cancelled appointment
    Given appointment 7001 is cancelled
    When I check in appointment 7001
    Then the request is rejected with status 422
    And the error message mentions "cancelled"
