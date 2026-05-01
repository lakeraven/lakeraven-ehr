@onc
Feature: Emergency Access (ONC § 170.315(d)(6))
  As a healthcare provider in an emergency situation
  I need to access patient records via break-the-glass
  So that I can provide emergency care while maintaining audit accountability

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |

  # ---------------------------------------------------------------------------
  # Granting emergency access
  # ---------------------------------------------------------------------------

  Scenario: Grant break-the-glass emergency access
    When provider "789" invokes emergency access for patient "1" with:
      | field         | value                                      |
      | reason        | medical_emergency                          |
      | justification | Patient unresponsive, need immediate vitals |
    Then the emergency access should be granted
    And the emergency access should have a security audit trail
    And the emergency access should expire after the default duration

  Scenario: Emergency access requires a valid reason
    When provider "789" attempts emergency access with an invalid reason
    Then the emergency access should be denied

  Scenario: Emergency access requires patient and provider
    When emergency access is attempted with missing required fields
    Then the emergency access should be denied

  # ---------------------------------------------------------------------------
  # Active access checks
  # ---------------------------------------------------------------------------

  Scenario: Check if provider has active emergency access
    Given provider "789" has active emergency access to patient "1"
    Then provider "789" should have active access to patient "1"
    And provider "999" should not have active access to patient "1"

  Scenario: Emergency access expires after the time window
    Given provider "789" has expired emergency access to patient "1"
    Then provider "789" should not have active access to patient "1"

  # ---------------------------------------------------------------------------
  # Post-access review
  # ---------------------------------------------------------------------------

  Scenario: Supervisor reviews emergency access as appropriate
    Given provider "789" has active emergency access to patient "1"
    When supervisor "SUP1" reviews the emergency access as "appropriate"
    Then the emergency access should be marked as reviewed
    And the review should have a security audit trail

  Scenario: Supervisor reviews emergency access as inappropriate
    Given provider "789" has active emergency access to patient "1"
    When supervisor "SUP1" reviews the emergency access as "inappropriate" with notes:
      | notes | Access not justified by clinical circumstances |
    Then the emergency access should be marked as reviewed
    And the review outcome should be "inappropriate"

  Scenario: Emergency access cannot be reviewed twice
    Given provider "789" has a reviewed emergency access to patient "1"
    When supervisor "SUP2" attempts to re-review the emergency access
    Then the re-review should be rejected

  # ---------------------------------------------------------------------------
  # Immutability
  # ---------------------------------------------------------------------------

  Scenario: Emergency access records cannot be modified
    Given provider "789" has active emergency access to patient "1"
    When an attempt is made to modify the emergency access record
    Then the modification should be rejected

  # ---------------------------------------------------------------------------
  # Pending reviews
  # ---------------------------------------------------------------------------

  Scenario: List pending emergency access reviews
    Given provider "789" has active emergency access to patient "1"
    And provider "456" has active emergency access to patient "1"
    Then there should be 2 emergency accesses pending review
