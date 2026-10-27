# frozen_string_literal: true

Feature: Authentication
  As a healthcare provider or staff member
  I want to authenticate with my RPMS credentials
  So that I can access the system securely

  # Sign-ons use the demo site personas (features/support/rpms_demo_site.rb),
  # whose access/verify pairs are published with the rpms-ops seed.
  Background:
    Given the authentication service is available

  # =============================================================================
  # VALID LOGIN SCENARIOS
  # =============================================================================

  Scenario: Provider logs in with valid access and verify codes
    When I login as "PMD123" with password "PMD123!!"
    Then I should be logged in successfully
    And my user type should be "provider"

  Scenario: Nurse logs in with valid credentials
    When I login as "PRN123" with password "PRN123!!"
    Then I should be logged in successfully
    And my user type should be "nurse"

  # The registration clerk and the scheduler hold only their package menus
  # (AGZMENU, SDZMENU) and USRCLS 0, so the engine resolves them as "user".
  Scenario: Registration clerk logs in with valid credentials
    When I login as "PREG123" with password "PREG123!!"
    Then I should be logged in successfully
    And my user type should be "user"

  Scenario: Scheduler logs in with valid credentials
    When I login as "PSCH123" with password "PSCH123!!"
    Then I should be logged in successfully
    And my user type should be "user"

  Scenario: Clerk logs in with valid credentials
    When I login as "PMA123" with password "PMA123!!"
    Then I should be logged in successfully
    And my user type should be "clerk"

  # =============================================================================
  # INVALID LOGIN SCENARIOS
  # =============================================================================

  Scenario: Login fails with invalid access code
    When I login as "INVALID" with password "test123"
    Then I should see an authentication error "Invalid"
    And I should not be logged in

  Scenario: Login fails with a wrong verify code
    When I login as "PMD123" with password "NOT-THE-CODE"
    Then I should see an authentication error "Invalid"
    And I should not be logged in

  Scenario: Login fails with invalid verify code
    When I login as "PMD123" with password ""
    Then I should see an authentication error "Password required"
    And I should not be logged in

  # =============================================================================
  # LOGOUT SCENARIOS
  # =============================================================================

  Scenario: User logs out successfully
    Given I am logged in as a provider
    When I log out
    Then I should be logged out

  # =============================================================================
  # ROLE-BASED PERMISSIONS
  # =============================================================================

  Scenario: Provider can view and create referrals
    Given I am logged in as a provider
    Then I should have permission to "view_patients"
    And I should have permission to "view_referrals"
    And I should have permission to "create_referrals"
    And I should have permission to "edit_own_referrals"
    But I should not have permission to "approve_referrals"

  Scenario: Nurse can view patients and referrals
    Given I am logged in as a nurse
    Then I should have permission to "view_patients"
    And I should have permission to "view_referrals"
    And I should have permission to "update_referral_status"
    But I should not have permission to "create_referrals"

  Scenario: Clerk has limited view permissions
    Given I am logged in as a clerk
    Then I should have permission to "view_patients"
    And I should have permission to "view_referrals"
    But I should not have permission to "create_referrals"
    And I should not have permission to "approve_referrals"

  Scenario: Case manager can approve and manage referrals
    Given I am logged in as a case_manager
    Then I should have permission to "view_patients"
    And I should have permission to "view_referrals"
    And I should have permission to "approve_referrals"
    And I should have permission to "deny_referrals"
    And I should have permission to "manage_referrals"

  # =============================================================================
  # SECURITY KEY CHECKS
  # =============================================================================

  Scenario: User with PRCFA SUPERVISOR key can approve CHS
    Given I am logged in as a case_manager with security key "PRCFA SUPERVISOR"
    Then I should be able to approve CHS referrals

  Scenario: User without PRCFA SUPERVISOR key cannot approve CHS
    Given I am logged in as a clerk without security keys
    Then I should not be able to approve CHS referrals

  Scenario: User with PRCFA TECH key can process CHS claims
    Given I am logged in as a clerk with security key "PRCFA TECH"
    Then I should be able to process CHS claims

  Scenario: User with GMRC MGR key can manage consults
    Given I am logged in as a nurse with security key "GMRC MGR"
    Then I should be able to manage consults

  # =============================================================================
  # UNAUTHENTICATED ACCESS
  # =============================================================================

  Scenario: Unauthenticated user has no permissions
    Given I am not logged in
    Then I should not have a current user
