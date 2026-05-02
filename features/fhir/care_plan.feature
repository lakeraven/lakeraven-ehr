# frozen_string_literal: true

Feature: CarePlan FHIR resource
  As a healthcare system
  I need to represent patient care plans
  So that treatment plans are interoperable

  Scenario: Create a valid care plan
    Given a care plan with title "Diabetes Management" for patient "100"
    Then the care plan should be valid

  Scenario: Care plan requires patient
    Given a care plan without a patient
    Then the care plan should be invalid

  Scenario: Care plan is active by default
    Given a care plan with title "Diabetes Management" for patient "100"
    Then the care plan should be active

  Scenario: Care plan with category
    Given a care plan with title "PT Plan" and category "assess-plan" for patient "100"
    Then the care plan should be valid

  Scenario: FHIR CarePlan includes resourceType
    Given a care plan with title "Diabetes Management" for patient "100"
    When I serialize the care plan to FHIR
    Then the FHIR resourceType should be "CarePlan"

  Scenario: FHIR CarePlan includes subject reference
    Given a care plan with title "Diabetes Management" for patient "100"
    When I serialize the care plan to FHIR
    Then the FHIR subject reference should include "100"

  Scenario: FHIR CarePlan includes status and intent
    Given a care plan with title "Diabetes Management" for patient "100"
    When I serialize the care plan to FHIR
    Then the FHIR care plan status should be "active"
    And the FHIR care plan intent should be "plan"

  Scenario: FHIR CarePlan includes title
    Given a care plan with title "Diabetes Management" for patient "100"
    When I serialize the care plan to FHIR
    Then the FHIR care plan title should be "Diabetes Management"
