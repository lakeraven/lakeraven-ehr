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

  @S-REG-02.3
  Scenario: A patient already on file with the same name, date of birth and sex is shown before anything is filed
    Given "Anderson,Alice", record 1, has health record number "101226" at facility 7819
    And the signed-on user's facility is 7819
    When I register a patient with:
      | Name (LAST,FIRST)      | Anderson,Alice    |
      | Sex                    | Female            |
      | Date of birth          | 1980-05-15        |
      | Tribe of membership    | EXAMPLE TRIBE     |
      | Community of residence | EXAMPLE COMMUNITY |
    Then I am shown "Anderson,Alice" as a possible match with health record number "101226"
    And no registration write was sent to RPMS
    And I can open that registration instead

  @S-REG-02.4
  Scenario: A name that is not LAST,FIRST or is too long is refused and the format named
    When I register a patient with:
      | Name (LAST,FIRST)      | ALICE ANDERSON    |
      | Sex                    | Female            |
      | Date of birth          | 1990-01-02        |
      | Tribe of membership    | EXAMPLE TRIBE     |
      | Community of residence | EXAMPLE COMMUNITY |
    Then the registration is refused, naming "Name must be LAST,FIRST MIDDLE"
    And no registration write was sent to RPMS

  @S-REG-02.5
  Scenario: A date of birth in the future is refused
    When I register a patient with:
      | Name (LAST,FIRST)      | DEMOPATIENT,TRE   |
      | Sex                    | Female            |
      | Date of birth          | 2099-01-02        |
      | Tribe of membership    | EXAMPLE TRIBE     |
      | Community of residence | EXAMPLE COMMUNITY |
    Then the registration is refused, naming "Date of birth cannot be in the future"
    And no registration write was sent to RPMS

  @S-REG-02.7
  Scenario: A social security number that is not nine digits is refused and the format named
    When I register a patient with:
      | Name (LAST,FIRST)                 | DEMOPATIENT,QUATRO |
      | Sex                               | Female             |
      | Date of birth                     | 1990-01-02         |
      | Social security number (optional) | 12345              |
      | Tribe of membership               | EXAMPLE TRIBE      |
      | Community of residence            | EXAMPLE COMMUNITY  |
    Then the registration is refused, naming "Social security number must be nine digits"
    And no registration write was sent to RPMS

  @S-REG-02.8
  Scenario: A social security number already on another patient is refused and nothing is filed
    Given "111-11-1111" is the social security number of "Anderson,Alice" in PATIENT (#2)
    When I register a patient with:
      | Name (LAST,FIRST)                 | DEMOPATIENT,CINQ  |
      | Sex                               | Female            |
      | Date of birth                     | 1990-01-02        |
      | Social security number (optional) | 111-11-1111       |
      | Tribe of membership               | EXAMPLE TRIBE     |
      | Community of residence            | EXAMPLE COMMUNITY |
    Then the registration is refused, naming "Social security number is already on another patient"
    And no registration write was sent to RPMS

  @S-REG-02.15
  Scenario: Without a registration key I cannot add a patient
    Given the front desk clerk is signed on holding only "AGZVIEWONLY"
    When I open registration
    Then I cannot add a patient

  @S-REG-02.2
  Scenario: A missing required value refuses the registration and names it
    When I register a patient with:
      | Name (LAST,FIRST)   | DEMOPATIENT,DUO |
      | Sex                 | Female          |
      | Date of birth       | 1990-01-02      |
      | Tribe of membership | EXAMPLE TRIBE   |
    Then the registration is refused, naming "Community of residence"
    And no registration write was sent to RPMS
