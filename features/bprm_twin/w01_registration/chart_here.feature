# rpms-ux S-REG-06 Give a patient from another facility a chart here
# (docs/bprm/scenarios.tsv).
#
# Backing: RpmsRpc.mock! (test/test_helper.rb). The HRN read is DDR GETS ENTRY
# DATA over #9000001.41 (seeded as the Given); the write is DDR FILER "ADD"
# with the two HEALTH RECORD multiple rows RpmsRpc::Registration files on a
# new registration, under the ^AUPNPAT(DFN) lock, seeded the way the gem's
# own tests seed DDR FILER. A pass proves the screen sends exactly those rows
# and refuses what it must; nothing reads FileMan back. Evidence grade: mock
# (lakeraven-ehr#484); not parity.
@bprm_twin @registration @W01
Feature: Give a patient from another facility a chart here (S-REG-06)

  Background:
    Given the signed-on user's facility is 7819

  @S-REG-06.1
  Scenario: A patient with a chart elsewhere gets a health record number here
    Given the front desk clerk is signed on
    And "Anderson,Alice", record 1, has no health record number at facility 7819
    And RPMS will accept a chart number for record 1 at facility 7819
    When I give record 1 the chart number "100042" at this facility
    Then RPMS was sent the HEALTH RECORD multiple (#9000001.41) rows for record 1 at facility 7819 with number "100042"
    And the page says health record number "100042" was filed

  @S-REG-06.2
  Scenario: A patient who already has a chart here is refused and nothing is filed
    Given the front desk clerk is signed on
    And "Anderson,Alice", record 1, has health record number "101226" at facility 7819
    When I give record 1 the chart number "100042" at this facility
    Then I am told the patient is already registered at this facility
    And no chart number write was sent to RPMS

  @S-REG-06.4
  Scenario: With the view-only key I cannot add a chart number here
    Given the front desk clerk is signed on holding only "AGZVIEWONLY"
    When I try to give record 1 a chart number at this facility
    Then it is refused for want of a registration key
