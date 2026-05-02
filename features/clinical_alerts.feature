# frozen_string_literal: true

Feature: Clinical alert aggregation
  As a healthcare provider
  I need to see clinical alerts aggregated from multiple sources
  So that I can quickly assess patient safety concerns

  Scenario: DUE reminders generate alerts
    Given clinical reminders:
      | name                  | status | priority |
      | Diabetic Eye Exam     | DUE    | high     |
      | Flu Vaccine           | DUE    | low      |
    When I aggregate background alerts
    Then there should be 2 alerts
    And the first alert type should be "reminder"

  Scenario: Non-DUE reminders are filtered out
    Given clinical reminders:
      | name              | status     | priority |
      | Diabetic Eye Exam | DUE        | high     |
      | Flu Vaccine       | RESOLVED   |          |
      | Colonoscopy       | NOT DUE    |          |
    When I aggregate background alerts
    Then there should be 1 alert

  Scenario: High priority reminder maps to high severity
    Given clinical reminders:
      | name              | status | priority |
      | Diabetic Eye Exam | DUE    | high     |
    When I aggregate background alerts
    Then the first alert severity should be "high"

  Scenario: Low priority reminder maps to low severity
    Given clinical reminders:
      | name        | status | priority |
      | Flu Vaccine | DUE    | low      |
    When I aggregate background alerts
    Then the first alert severity should be "low"

  Scenario: Default reminder severity is moderate
    Given clinical reminders:
      | name        | status | priority |
      | A1C Check   | DUE    |          |
    When I aggregate background alerts
    Then the first alert severity should be "moderate"

  Scenario: Allergy alerts from active allergies
    Given patient allergies:
      | allergen   | severity | criticality |
      | Penicillin | severe   |             |
      | Aspirin    | mild     |             |
    When I aggregate background alerts
    Then there should be 2 alerts
    And the first alert type should be "allergy"

  Scenario: Severe allergy maps to high severity
    Given patient allergies:
      | allergen   | severity | criticality |
      | Penicillin | severe   |             |
    When I aggregate background alerts
    Then the first alert severity should be "high"

  Scenario: Moderate allergy maps to moderate severity
    Given patient allergies:
      | allergen   | severity | criticality |
      | Latex      | moderate |             |
    When I aggregate background alerts
    Then the first alert severity should be "moderate"

  Scenario: Mild allergy maps to low severity
    Given patient allergies:
      | allergen   | severity | criticality |
      | Aspirin    | mild     |             |
    When I aggregate background alerts
    Then the first alert severity should be "low"

  Scenario: Criticality fallback when severity is nil
    Given patient allergies:
      | allergen   | severity | criticality |
      | Codeine    |          | high        |
    When I aggregate background alerts
    Then the first alert severity should be "high"

  Scenario: Criticality low fallback
    Given patient allergies:
      | allergen | severity | criticality |
      | Dust     |          | low         |
    When I aggregate background alerts
    Then the first alert severity should be "low"

  Scenario: Default severity is moderate when no severity or criticality
    Given patient allergies:
      | allergen | severity | criticality |
      | Shellfish |         |             |
    When I aggregate background alerts
    Then the first alert severity should be "moderate"

  Scenario: Drug interactions list is intentionally empty
    Given patient allergies:
      | allergen   | severity | criticality |
      | Penicillin | severe   |             |
    When I check drug interactions
    Then the drug interactions should be empty

  Scenario: Severity summary counts
    Given clinical reminders:
      | name              | status | priority |
      | Diabetic Eye Exam | DUE    | high     |
      | Flu Vaccine       | DUE    | low      |
    And patient allergies:
      | allergen   | severity | criticality |
      | Penicillin | severe   |             |
    When I aggregate background alerts
    Then the severity summary should show 2 high alerts
    And the severity summary should show 0 moderate alerts
    And the severity summary should show 1 low alert

  Scenario: Mixed reminders and allergies
    Given clinical reminders:
      | name          | status | priority |
      | A1C Check     | DUE    |          |
    And patient allergies:
      | allergen   | severity | criticality |
      | Penicillin | severe   |             |
    When I aggregate background alerts
    Then there should be 2 alerts
