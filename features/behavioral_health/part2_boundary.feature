@part2_pending
Feature: 42 CFR Part 2 Boundaries (Issue #560)
  As a Part 2 program operator
  I want substance use disorder (SUD) data segmented from shared records
  So that the pilot does not foreclose compliance in April

  Scenario: R1 - Substance use diagnoses are not written to shared RPMS problem list
    When I add a substance use diagnosis to the patient's problem list
    Then the diagnosis is NOT written to the shared RPMS files

  Scenario: R3 - The system provides a specific consent slot for substance-use counseling
    When I check the available consent scopes
    Then there must be a specific scope for "substance-use counseling notes"

  Scenario: R4 - Export paths call a Part 2 filter before returning data
    When a C-CDA is requested for the patient
    Then the data is passed through the Part 2 egress filter
