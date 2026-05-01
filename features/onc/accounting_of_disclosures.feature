@onc
Feature: Accounting of Disclosures (ONC § 170.315(d)(11))
  As a patient or privacy officer
  I need to track and review all disclosures of protected health information
  So that HIPAA § 164.528 accounting of disclosures requirements are met

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |

  # ---------------------------------------------------------------------------
  # Recording disclosures
  # ---------------------------------------------------------------------------

  Scenario: Record a PHI disclosure to an external party
    When a disclosure is recorded for patient "1" with:
      | field               | value                              |
      | recipient_name      | Ulster County Health Department    |
      | recipient_type      | Public Health Authority             |
      | purpose             | public_health                      |
      | data_disclosed      | Laboratory results, Demographics   |
      | disclosed_by        | 789                                |
    Then the disclosure should be recorded successfully
    And the disclosure should be immutable
    And the disclosure should have an audit trail entry

  Scenario: Disclosure requires patient, recipient, and purpose
    When a disclosure is recorded with missing required fields
    Then the disclosure should fail validation

  # ---------------------------------------------------------------------------
  # Patient-facing disclosure report
  # ---------------------------------------------------------------------------

  Scenario: Patient requests accounting of disclosures
    Given patient "1" has the following recent disclosure history:
      | recipient_name                   | purpose        | months_ago |
      | Ulster County Health Department  | public_health  | 3          |
      | NYS ECLRS                       | public_health  | 2          |
      | External Lab Corp               | treatment      | 1          |
    When patient "1" requests their accounting of disclosures
    Then the report should contain 3 disclosures
    And each disclosure should include the date, recipient, and purpose
    And the disclosures should be in reverse chronological order

  Scenario: Accounting of disclosures covers the past 6 years
    Given patient "1" has a disclosure from 5 years ago
    And patient "1" has a disclosure from 7 years ago
    When patient "1" requests their accounting of disclosures
    Then the report should contain 1 disclosure
    And the 7-year-old disclosure should be excluded

  # ---------------------------------------------------------------------------
  # Disclosure report export
  # ---------------------------------------------------------------------------

  Scenario: Export disclosure report as structured data
    Given patient "1" has the following recent disclosure history:
      | recipient_name                   | purpose        | months_ago |
      | Ulster County Health Department  | public_health  | 1          |
    When the disclosure report is exported for patient "1"
    Then the export should include patient identifier
    And the export should include disclosure details
    And the export should include the reporting period

  # ---------------------------------------------------------------------------
  # Immutability and audit
  # ---------------------------------------------------------------------------

  Scenario: Disclosure records cannot be modified
    Given patient "1" has a recorded disclosure
    When an attempt is made to modify the disclosure
    Then the modification should be rejected

  Scenario: Disclosure records cannot be deleted
    Given patient "1" has a recorded disclosure
    When an attempt is made to delete the disclosure
    Then the deletion should be rejected

  # ---------------------------------------------------------------------------
  # Performance
  # ---------------------------------------------------------------------------

  Scenario: Disclosure recording completes within acceptable time
    When a disclosure is recorded with timing for patient "1"
    Then the disclosure recording should complete within 2 seconds
