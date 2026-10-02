# rpms-ux S-REG-02 Register a new patient (docs/bprm/scenarios.tsv).
#
# Backing: RpmsRpc.mock! (test/test_helper.rb). The broker replies are seeded
# the way rpms-rpc's own tests seed them (test/rpms_rpc/api/registration_test.rb
# at the pinned ref): the AGG ADD NEW PATIENT / AGG UPDATE PATIENT recordset
# replies and a DDR FILER "[Data]" reply.
#
# What a pass proves: the screen refuses what it must refuse before anything
# reaches the broker, and sends the registration to RPMS on the AG path with
# the right content. It does NOT read FileMan back: PATIENT (#2), IHS PATIENT
# (#9000001) and the health record number are asserted as the writes sent,
# not as state. Evidence grade: mock (lakeraven-ehr#484); not parity.
@bprm_twin @registration @W01
Feature: Register a new patient (S-REG-02)

  Background:
    Given the front desk clerk is signed on
    And RPMS has the AG registration service
    And the tribe list holds "EXAMPLE TRIBE" as tribe 41

  @S-REG-02.1
  Scenario: A new patient is filed with a health record number for this facility
    Given no chart exists for "DEMOPATIENT,UNA"
    And RPMS will file the next new patient as record 9
    When I register a patient with:
      | Name (LAST,FIRST)      | DEMOPATIENT,UNA   |
      | Sex                    | Female            |
      | Date of birth          | 1990-01-02        |
      | Tribe of membership    | EXAMPLE TRIBE     |
      | Community of residence | EXAMPLE COMMUNITY |
    Then RPMS was sent a new patient "DEMOPATIENT,UNA", female, born 01/02/1990, on the AG registration path
    And health record number 9 was filed for record 9
    And tribe 41 and community "EXAMPLE COMMUNITY" were filed on IHS PATIENT (#9000001) record 9
    And the page says "DEMOPATIENT,UNA" is registered with health record number 9

  @S-REG-02.2
  Scenario: A missing required value refuses the registration and names it
    When I register a patient with:
      | Name (LAST,FIRST)   | DEMOPATIENT,DUO |
      | Sex                 | Female          |
      | Date of birth       | 1990-01-02      |
      | Tribe of membership | EXAMPLE TRIBE   |
    Then the registration is refused, naming "Community of residence"
    And no registration write was sent to RPMS
