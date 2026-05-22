Feature: Enter a set of vitals on an open encounter
  As a clinical provider
  I need to record vital signs against the patient's open visit
  So that the encounter has complete clinical documentation

  Background:
    Given a patient with DFN 8791
    And an open encounter "492;3260514.09;A;2090059" at location 349

  Scenario: Provider saves a complete vitals set
    When the provider enters the following vitals:
      | abbreviation | value   | units |
      | TMP          | 97      | F     |
      | PU           | 80      | /min  |
      | BP           | 130/90  | mmHg  |
    Then the vitals save should succeed
    And 3 measurements should be recorded
    And the gateway should receive a save with 3 measurements

  Scenario: Provider tries to save an empty vitals set
    When the provider enters no vitals
    Then the vitals save should fail with :no_measurements

  Scenario: Provider tries to save without a visit
    When the provider enters the following vitals without a visit context:
      | abbreviation | value | units |
      | TMP          | 98    | F     |
    Then the vitals save should fail with :invalid_input
