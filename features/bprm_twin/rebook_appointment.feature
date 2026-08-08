# BPRM twin — scenario #10: Rebook (cancel + book, composite)
# HTTP:  POST /appointments/:id/rebook
# RPC:   BSDX CANCEL APPOINTMENT (-> $$CANCEL^BSDAPI) then BSDX ADD APPOINTMENT (-> $$ADD^BSDAPI)
# BPRM:  composite of BsdSetPatientAppointmentCancel + BsdSetPatientAppointment
# Disposition: sql-mutate -> reimpl  (must be atomic-ish: cancel then rebook; roll back the cancel if the rebook fails)
@bprm_twin @scheduling
Feature: Rebook an appointment
  As a scheduling clerk
  I want to move a patient's appointment to a new time in one action
  So that the old slot frees and the new slot is confirmed without a gap

  Background:
    Given a registered patient with DFN 42
    And patient 42 has appointment 7001 in clinic 15 at "2026-08-20 09:00"
    And clinic 15 has an open slot at "2026-08-21 10:00" of length 20 minutes

  Scenario: Rebook to a new open slot
    When I rebook appointment 7001 to clinic 15 at "2026-08-21 10:00" with reason "Patient request"
    Then the rebook succeeds
    And the "2026-08-20 09:00" slot in clinic 15 is open again
    And a new appointment exists for patient 42 at "2026-08-21 10:00"

  Scenario: If the new slot is unavailable the original appointment is preserved
    Given clinic 15 has patient 43 booked at "2026-08-21 10:00"
    When I rebook appointment 7001 to clinic 15 at "2026-08-21 10:00" with reason "Patient request"
    Then the rebook is rejected with status 409
    And appointment 7001 is still booked at "2026-08-20 09:00"
