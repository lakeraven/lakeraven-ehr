Feature: VAERS Export
  As a clinical staff member
  I need to export adverse event data in VAERS format
  So that I can report vaccine adverse events to the CDC

  Background:
    Given I am logged in as a provider

  Scenario: Export VAERS report for a patient with immunization and adverse reaction
    Given a patient with DFN "1" has immunizations in RPMS
    And the patient has adverse reactions in RPMS
    When I generate a VAERS export for patient "1" and immunization "IMM-1"
    Then I should receive a VAERS-formatted report
    And the report should include patient demographics
    And the report should include vaccine information

  Scenario: VAERS export sources patient data from Patient model
    Given a patient with DFN "1" has immunizations in RPMS
    When I generate a VAERS export for patient "1" and immunization "IMM-1"
    Then the Patient model should have been called for demographics
    And the ImmunizationGateway should have been called for vaccine data

  Scenario: VAERS report validates required fields
    When I attempt to create a VAERS report without required fields
    Then the report should be invalid
    And the validation errors should indicate missing fields

  Scenario: VAERS export produces CSV output
    Given a patient with DFN "1" has immunizations in RPMS
    And the patient has adverse reactions in RPMS
    When I generate a VAERS CSV export for patient "1" and immunization "IMM-1"
    Then I should receive a CSV string with VAERS headers
