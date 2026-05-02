# frozen_string_literal: true

Feature: FHIR Bundle import for clinical reconciliation
  As a clinician
  I need to import clinical data from FHIR Bundles
  So that I can reconcile external data with patient records

  Scenario: Import valid FHIR Bundle with allergies
    Given a FHIR Bundle JSON with an AllergyIntolerance for patient "100"
    When I import the bundle for patient "100" as clinician "201"
    Then the bundle import should succeed

  Scenario: Import valid FHIR Bundle with conditions
    Given a FHIR Bundle JSON with a Condition for patient "100"
    When I import the bundle for patient "100" as clinician "201"
    Then the bundle import should succeed

  Scenario: Import valid FHIR Bundle with medications
    Given a FHIR Bundle JSON with a MedicationRequest for patient "100"
    When I import the bundle for patient "100" as clinician "201"
    Then the bundle import should succeed

  Scenario: Reject invalid JSON
    Given invalid JSON input
    When I import the bundle for patient "100" as clinician "201"
    Then the bundle import should fail
    And the bundle import error should include "Invalid JSON"

  Scenario: Reject non-Bundle resource
    Given a FHIR JSON that is not a Bundle
    When I import the bundle for patient "100" as clinician "201"
    Then the bundle import should fail
    And the bundle import error should include "Expected Bundle"

  Scenario: Reject Bundle with wrong patient
    Given a FHIR Bundle JSON with an AllergyIntolerance for patient "999"
    When I import the bundle for patient "100" as clinician "201"
    Then the bundle import should fail
    And the bundle import error should include "different patient"

  Scenario: Import Bundle with mixed resource types
    Given a FHIR Bundle JSON with allergies, conditions, and medications for patient "100"
    When I import the bundle for patient "100" as clinician "201"
    Then the bundle import should succeed
