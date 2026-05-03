# frozen_string_literal: true

Feature: Clinical decision support rules
  As a healthcare system
  I need configurable CDS rules for conditions, demographics, and devices
  So that clinical alerts are evidence-based and controllable

  # --- Rule configuration ---

  Scenario: CDS rules are loaded from configuration
    When I list all CDS rules
    Then there should be at least 1 rule
    And each rule should have an id and message

  Scenario: Find a rule by ID
    When I look up rule "diabetes_monitoring"
    Then the rule should exist
    And the rule message should mention "Diabetes"

  Scenario: Rules are enabled by default
    When I check if rule "diabetes_monitoring" is enabled
    Then the rule should be enabled

  Scenario: Disable a CDS rule
    When provider "201" disables rule "diabetes_monitoring"
    Then rule "diabetes_monitoring" should be disabled

  Scenario: Re-enable a disabled rule
    Given provider "201" has disabled rule "diabetes_monitoring"
    When provider "201" enables rule "diabetes_monitoring"
    Then rule "diabetes_monitoring" should be enabled

  Scenario: Rule override records provider and timestamp
    When provider "201" disables rule "diabetes_monitoring"
    Then the override result should include provider "201"
    And the override result should include a timestamp

  # --- CdsResult ---

  Scenario: CdsResult with no alerts
    Given a CDS result with no alerts
    Then the result should not have alerts
    And the result summary should be "No clinical alerts"

  Scenario: CdsResult with alerts
    Given a CDS result with alerts:
      | category        | severity | message               |
      | drug-interaction | critical | Warfarin + Aspirin    |
      | lab-result       | warning  | A1C elevated          |
    Then the result should have alerts
    And the result should have 2 alerts

  Scenario: CdsResult filters by category
    Given a CDS result with alerts:
      | category        | severity | message               |
      | drug-interaction | critical | Warfarin + Aspirin    |
      | lab-result       | warning  | A1C elevated          |
      | drug-interaction | warning  | Metformin + Contrast  |
    When I filter alerts by category "drug-interaction"
    Then there should be 2 filtered alerts

  Scenario: CdsResult filters critical alerts
    Given a CDS result with alerts:
      | category        | severity | message               |
      | drug-interaction | critical | Warfarin + Aspirin    |
      | lab-result       | warning  | A1C elevated          |
    When I filter critical alerts
    Then there should be 1 critical alert

  Scenario: CdsResult summary describes alert counts
    Given a CDS result with alerts:
      | category        | severity | message               |
      | drug-interaction | critical | Warfarin + Aspirin    |
      | lab-result       | warning  | A1C elevated          |
    Then the result summary should include "2 alert(s)"

  Scenario: CdsResult to_h includes all fields
    Given a CDS result with alerts:
      | category        | severity | message               |
      | drug-interaction | critical | Warfarin + Aspirin    |
    When I convert the result to a hash
    Then the hash should include patient_dfn
    And the hash should include alert_count 1

  # --- Alert override ---

  Scenario: Override an alert with reason
    Given an alert with id "cds-di-001" and category "drug-interaction"
    When provider "201" overrides the alert with reason "Clinically appropriate"
    Then the override should be recorded
    And the override should include the original alert
    And the override reason should be "Clinically appropriate"
