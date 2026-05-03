# frozen_string_literal: true

Feature: Immunization FHIR resource
  As a healthcare system
  I need to represent patient immunizations
  So that vaccination data is interoperable

  Scenario: Create a valid immunization
    Given an immunization with vaccine "Influenza" for patient "100"
    Then the immunization should be valid

  Scenario: Immunization requires patient
    Given an immunization without a patient
    Then the immunization should be invalid

  Scenario: Immunization requires vaccine display
    Given an immunization without a vaccine for patient "100"
    Then the immunization should be invalid

  Scenario: Completed immunization
    Given a completed immunization with vaccine "Influenza" for patient "100"
    Then the immunization should be completed

  Scenario: Immunization with CVX code
    Given an immunization with vaccine "Influenza" and CVX "158" for patient "100"
    Then the immunization should be valid

  Scenario: Immunization with VFC eligibility
    Given an immunization with vaccine "Influenza" and VFC "V02" for patient "100"
    Then the immunization should be valid

  Scenario: FHIR Immunization includes resourceType
    Given an immunization with vaccine "Influenza" for patient "100"
    When I serialize the immunization to FHIR
    Then the FHIR resourceType should be "Immunization"

  Scenario: FHIR Immunization includes patient reference
    Given an immunization with vaccine "Influenza" for patient "100"
    When I serialize the immunization to FHIR
    Then the FHIR immunization patient reference should include "100"

  Scenario: FHIR Immunization includes vaccine code
    Given an immunization with vaccine "Influenza" and CVX "158" for patient "100"
    When I serialize the immunization to FHIR
    Then the FHIR vaccine code should include "158"
