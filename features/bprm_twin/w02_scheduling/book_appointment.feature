# rpms-ux S-SCH-01 Book an appointment (docs/bprm/scenarios.tsv).
#
# Backing: RpmsRpc.mock! (test/test_helper.rb). The BSDX ADD NEW APPOINTMENT
# reply is seeded the way rpms-rpc's own tests seed it
# (test/rpms_rpc/api/scheduling_test.rb at the pinned ref), keyed by the
# FileMan start time the gem sends.
#
# What a pass proves: the screen refuses what it must refuse before anything
# reaches the broker, and sends the booking to RPMS through the confirmed
# BSDX write with the right content. S-SCH-01.1's Then (the appointment on
# the clinic's schedule and in the patient's appointments) needs a read-back
# this slice does not have, so that scenario ends PENDING and says why.
# Evidence grade: mock (lakeraven-ehr#484); not parity.
@bprm_twin @scheduling @W02
Feature: Book an appointment (S-SCH-01)

  Background:
    Given the scheduler is signed on

  @S-SCH-01.1
  Scenario: A registered patient is booked into an open slot
    Given a clinic resource "GENERAL MEDICINE" with an open slot on "2026-10-15" at "09:00"
    And RPMS will file the next appointment as 501
    When I book an appointment with:
      | Clinic                | GENERAL MEDICINE |
      | Patient record number | 1                |
      | Date                  | 2026-10-15       |
      | Time                  | 09:00            |
      | Length in minutes     | 20               |
    Then RPMS was sent a BSDX booking for patient 1 in "GENERAL MEDICINE" on "2026-10-15" at "09:00" for 20 minutes
    And the page says "Anderson,Alice" is booked and RPMS filed appointment 501
    And the appointment shows on the clinic's schedule and in the patient's appointments

  @S-SCH-01.3
  Scenario: A booking with no patient, date, time or length is refused and names the value
    When I book an appointment with:
      | Clinic            | GENERAL MEDICINE |
      | Length in minutes |                  |
    Then the booking is refused, naming "Patient record number", "Date", "Time" and "Length in minutes"
    And no booking was sent to RPMS

  @S-SCH-01.4
  Scenario: A note with a semicolon is refused
    When I book an appointment with:
      | Clinic                | GENERAL MEDICINE  |
      | Patient record number | 1                 |
      | Date                  | 2026-10-15        |
      | Time                  | 09:00             |
      | Length in minutes     | 20                |
      | Note                  | follow-up; bring x-rays |
    Then the booking is refused, naming "Note"
    And no booking was sent to RPMS
