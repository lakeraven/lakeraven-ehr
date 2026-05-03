# frozen_string_literal: true

Feature: MedicationRequest FHIR resource
  As a healthcare system
  I need to represent medication orders
  So that prescription data is interoperable

  Scenario: Create a valid medication request
    Given a medication request for "Metformin 500mg" for patient "100"
    Then the medication request should be valid

  Scenario: Medication request requires patient
    Given a medication request without a patient
    Then the medication request should be invalid

  Scenario: Medication request requires medication display
    Given a medication request without a medication for patient "100"
    Then the medication request should be invalid

  Scenario: Active medication request
    Given a medication request for "Metformin 500mg" with status "active" for patient "100"
    Then the medication request should be active

  Scenario: Medication matching key with RxNorm code
    Given a medication request for "Metformin 500mg" with RxNorm "860975" for patient "100"
    Then the medication matching key should be "rxnorm:860975"

  Scenario: Signed content hash
    Given a medication request for "Metformin 500mg" for patient "100"
    Then the medication request should have a signed content hash

  Scenario: FHIR MedicationRequest includes resourceType
    Given a medication request for "Metformin 500mg" for patient "100"
    When I serialize the medication request to FHIR
    Then the FHIR resourceType should be "MedicationRequest"

  Scenario: FHIR MedicationRequest includes subject
    Given a medication request for "Metformin 500mg" for patient "100"
    When I serialize the medication request to FHIR
    Then the FHIR subject reference should include "100"

  Scenario: FHIR MedicationRequest includes medication
    Given a medication request for "Metformin 500mg" with RxNorm "860975" for patient "100"
    When I serialize the medication request to FHIR
    Then the FHIR medication code should include "860975"
