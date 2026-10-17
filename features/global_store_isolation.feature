# frozen_string_literal: true

Feature: Process-global store isolation between scenarios
  Scenarios in this file run in definition order. The second scenario fails when
  state from the first leaks, which makes the suite order-dependent.

  Scenario: A scenario leaves process-global state
    Given a synthetic provenance record for isolation patient "589"
    And provider "589" disables rule "diabetes_monitoring"
    And an isolation mock referral is seeded for patient DFN "1"

  Scenario: The following scenario starts with clean stores
    Then no provenance exists for isolation patient "589"
    And rule "diabetes_monitoring" should be enabled
    And no isolation mock referral exists for patient DFN "1"
    And mock patient DFN "1" resolves to "Anderson,Alice"
