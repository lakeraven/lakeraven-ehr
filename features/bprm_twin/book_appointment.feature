# BPRM twin — scenario #5: Book an appointment
# HTTP:  POST /clinics/:ien/appointments
# RPC:   BSDX ADD NEW APPOINTMENT  ->  APPADD^BSDX07  ->  $$MAKE^BSDAPI  ->  ^SC (S nodes) + ^BSDXAPPT (9002018.4)
#        (BSDX ADD APPOINTMENT is the post-write event-driver PROTOCOL, not the RPC)
# BPRM:  BsdSetPatientAppointment, BsdSetPatientAppointmentV4
# Disposition: sql-mutate -> reimpl  (BPRM raw-writes ^SC; BSDX/BSDAPI is the FileMan-safe path)
@bprm_twin @scheduling
Feature: Book an appointment
  As a scheduling clerk
  I want to book a patient into an open clinic slot
  So that they have a confirmed appointment

  Background:
    Given a registered patient with DFN 42 named "RAVEN,NORA"
    And a clinic "GENERAL MEDICINE" with IEN 15 in service area "Portland"
    And clinic 15 has an open slot at "2026-08-20 09:00" of length 20 minutes

  Scenario: Book an open slot
    When I book patient 42 into clinic 15 at "2026-08-20 09:00" for 20 minutes with note "Follow-up"
    Then the booking succeeds
    And a BSDX appointment id is returned
    And clinic 15 shows patient 42 booked at "2026-08-20 09:00"
    And the appointment is written through BSDAPI to ^SC (no raw global set)

  Scenario: Double-booking an occupied slot is rejected
    Given clinic 15 has patient 43 booked at "2026-08-20 09:00"
    When I book patient 42 into clinic 15 at "2026-08-20 09:00" for 20 minutes
    Then the booking is rejected with status 409
    And the error message mentions "not available"

  Scenario: Booking on an unknown clinic fails
    When I book patient 42 into clinic 999 at "2026-08-20 09:00" for 20 minutes
    Then the booking is rejected with status 422
    And the error message mentions "Clinic not on file"

  Scenario: Booking a patient with an overlapping appointment warns
    Given patient 42 already has an appointment at "2026-08-20 09:10"
    When I book patient 42 into clinic 15 at "2026-08-20 09:00" for 20 minutes
    Then the booking succeeds
    And the response warnings mention an overlapping appointment
