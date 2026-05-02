# frozen_string_literal: true

Feature: AllergyIntolerance FHIR resource
  As a healthcare system
  I need to represent patient allergies
  So that allergy data is interoperable

  Scenario: Active allergy
    Given an allergy to "Penicillin" for patient "100"
    Then the allergy should be active

  Scenario: Medication allergy
    Given a medication allergy to "Penicillin" for patient "100"
    Then the allergy should be a medication allergy

  Scenario: Food allergy
    Given a food allergy to "Peanuts" for patient "100"
    Then the allergy should be a food allergy

  Scenario: Allergy matching key with code
    Given an allergy to "Penicillin" with code "7980" for patient "100"
    Then the allergy matching key should be "rxnorm:7980"

  Scenario: FHIR AllergyIntolerance includes resourceType
    Given an allergy to "Penicillin" for patient "100"
    When I serialize the allergy to FHIR
    Then the FHIR resourceType should be "AllergyIntolerance"

  Scenario: FHIR AllergyIntolerance includes patient reference
    Given an allergy to "Penicillin" for patient "100"
    When I serialize the allergy to FHIR
    Then the FHIR allergy patient reference should include "100"

  Scenario: FHIR AllergyIntolerance includes allergen
    Given an allergy to "Penicillin" for patient "100"
    When I serialize the allergy to FHIR
    Then the FHIR allergy code text should be "Penicillin"
