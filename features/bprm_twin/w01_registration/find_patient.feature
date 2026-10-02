# rpms-ux S-REG-01 Find the patient before registering (docs/bprm/scenarios.tsv).
#
# Backing: RpmsRpc.mock! (test/test_helper.rb): the patient list is the one
# test_helper seeds for ORWPT LIST ALL / ORWPT ID INFO, and the health record
# number is seeded here as the DDR GETS ENTRY DATA read of #9000001.41 field
# .02 the screen performs. A pass proves the screen finds and lists what the
# broker returns; it says nothing about a live RPMS. Evidence grade: mock
# (lakeraven-ehr#484); not parity.
@bprm_twin @registration @lookup @W01
Feature: Find the patient before registering (S-REG-01)

  Background:
    Given the front desk clerk is signed on
    And the signed-on user's facility is 7819

  @S-REG-01.1
  Scenario: A registered patient is listed with their health record number
    Given "Anderson,Alice", record 1, has health record number "101226" at facility 7819
    When I search for "Anderson" born "1980-05-15"
    Then "Anderson,Alice" is listed with health record number "101226"
    And I can open their registration, which shows health record number "101226"

  @S-REG-01.2
  Scenario: No match offers to add a new patient
    When I search for "NOSUCHPATIENT"
    Then I am told no patient matches
    And I am offered to add a new patient
