# rpms-ux S-REG-20 Keep the patient's demographics current: the two scenarios
# about who may see and change a registration (docs/bprm/scenarios.tsv).
#
# Backing: RpmsRpc.mock! (test/test_helper.rb) for the patient read (ORWPT ID
# INFO); the keys come from the test session, the way a sign-on would carry
# them (SessionsController stores ORWU USERKEYS by name). A pass proves the
# screen gates on the key names BPRM gates on; it says nothing about whether
# a live RPMS user holds them. Evidence grade: mock (lakeraven-ehr#484).
@bprm_twin @registration @W01
Feature: Who may see and change a registration (S-REG-20)

  Background:
    Given the signed-on user's facility is 7819

  @S-REG-20.8
  Scenario: Without AGZVIEWSSN the social security number is not shown
    Given the front desk clerk is signed on holding only "AGZMENU"
    When I open the registration of record 1
    Then the social security number is not shown to me

  @S-REG-20.9
  Scenario: With only the view-only key I can see the registration and change nothing
    Given the front desk clerk is signed on holding only "AGZVIEWONLY"
    When I open the registration of record 1
    Then I see the registration of "Anderson,Alice"
    And I am offered nothing to change
    And opening the registration form is refused
