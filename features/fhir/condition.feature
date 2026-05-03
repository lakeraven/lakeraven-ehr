# frozen_string_literal: true

Feature: Condition FHIR resource
  As a healthcare system
  I need to represent patient conditions and diagnoses
  So that problem list data is interoperable

  Scenario: Create a valid condition
    Given a condition with display "Type 2 Diabetes" for patient "100"
    Then the condition should be valid

  Scenario: Condition requires patient
    Given a condition without a patient
    Then the condition should be invalid

  Scenario: Condition requires display
    Given a condition without a display for patient "100"
    Then the condition should be invalid

  Scenario: Active condition
    Given a condition with display "Type 2 Diabetes" and status "active" for patient "100"
    Then the condition should be active

  Scenario: Resolved condition
    Given a condition with display "Type 2 Diabetes" and status "resolved" for patient "100"
    Then the condition should be resolved

  Scenario: Problem list item
    Given a condition with display "Type 2 Diabetes" and category "problem-list-item" for patient "100"
    Then the condition should be a problem list item

  Scenario: Matching key with ICD code
    Given a condition with display "Type 2 Diabetes" and ICD code "E11.9" for patient "100"
    Then the condition matching key should be "icd10:E11.9"

  Scenario: FHIR Condition includes resourceType
    Given a condition with display "Type 2 Diabetes" for patient "100"
    When I serialize the condition to FHIR
    Then the FHIR resourceType should be "Condition"

  Scenario: FHIR Condition includes subject
    Given a condition with display "Type 2 Diabetes" for patient "100"
    When I serialize the condition to FHIR
    Then the FHIR subject reference should include "100"

  Scenario: FHIR Condition includes code
    Given a condition with display "Type 2 Diabetes" and ICD code "E11.9" for patient "100"
    When I serialize the condition to FHIR
    Then the FHIR condition code should include "E11.9"
