# rpms-ux S-SCH-02 Cancel or reschedule, the cancel half, and S-SCH-01.12
# (docs/bprm/scenarios.tsv).
#
# Backing: RpmsRpc.mock! (test/test_helper.rb). The BSDX CANCEL APPOINTMENT
# reply is seeded the way rpms-rpc's own tests seed it (an empty ERRORID row
# means success); the CANCELLATION REASONS (#409.2) picker is a DDR LISTER
# read seeded as the Given. A pass proves the screen refuses what it must
# before the broker and sends the cancellation with the right content; the
# Then of S-SCH-02.1 (the slot free, the status on the patient) needs a
# read-back this slice does not have, so it ends PENDING and says why.
# Evidence grade: mock (lakeraven-ehr#484); not parity.
@bprm_twin @scheduling @W02
Feature: Cancel an appointment (S-SCH-02)

  Background:
    Given the scheduler is signed on
    And the cancellation reasons hold "PATIENT ILL" as reason 3

  @S-SCH-02.1
  Scenario: A booked appointment is cancelled with a reason
    Given appointment 501 is booked
    And RPMS will accept the cancellation of appointment 501
    When I cancel appointment 501 with:
      | Cancelled by | The patient     |
      | Reason       | PATIENT ILL     |
      | Remarks      | called at 8am   |
    Then RPMS was sent a BSDX cancellation of appointment 501 by the patient for reason 3 with remarks "called at 8am"
    And the page says appointment 501 was cancelled on behalf of the patient
    And the slot is open again and the appointment is marked cancelled with the reason

  @S-SCH-02.2
  Scenario: A cancellation without who cancelled or a reason is refused and the appointment stays booked
    When I cancel appointment 501 with:
      | Remarks | called at 8am |
    Then the cancellation is refused, naming "Cancelled by" and "Reason"
    And no cancellation was sent to RPMS

  @S-SCH-02.3
  Scenario: Remarks shorter than 3 characters are refused
    When I cancel appointment 501 with:
      | Cancelled by | The clinic  |
      | Reason       | PATIENT ILL |
      | Remarks      | no          |
    Then the cancellation is refused, naming "Remarks"
    And no cancellation was sent to RPMS

  @S-SCH-01.12
  Scenario: Without a scheduling key I can neither book nor cancel
    Given the scheduler is signed on holding only "no keys"
    When I open the booking form
    Then it is refused for want of a scheduling key
    When I open the cancellation form for appointment 501
    Then it is refused for want of a scheduling key
