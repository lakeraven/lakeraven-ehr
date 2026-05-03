# frozen_string_literal: true

Feature: Goal FHIR resource
  As a healthcare system
  I need to represent patient goals
  So that treatment objectives are interoperable

  Scenario: Create a valid goal
    Given a goal with description "A1C below 7%" for patient "100"
    Then the goal should be valid

  Scenario: Goal requires patient
    Given a goal without a patient
    Then the goal should be invalid

  Scenario: Goal requires description
    Given a goal without a description for patient "100"
    Then the goal should be invalid

  Scenario: Goal is active by default
    Given a goal with description "A1C below 7%" for patient "100"
    Then the goal should be active

  Scenario: Goal with achievement status
    Given a goal with description "A1C below 7%" and achievement "achieved" for patient "100"
    Then the goal should be achieved

  Scenario: Goal with target date
    Given a goal with description "A1C below 7%" and target "2026-12-31" for patient "100"
    Then the goal should be valid

  Scenario: FHIR Goal includes resourceType
    Given a goal with description "A1C below 7%" for patient "100"
    When I serialize the goal to FHIR
    Then the FHIR resourceType should be "Goal"

  Scenario: FHIR Goal includes subject
    Given a goal with description "A1C below 7%" for patient "100"
    When I serialize the goal to FHIR
    Then the FHIR subject reference should include "100"

  Scenario: FHIR Goal includes lifecycle status
    Given a goal with description "A1C below 7%" for patient "100"
    When I serialize the goal to FHIR
    Then the FHIR goal lifecycle status should be "active"

  Scenario: FHIR Goal includes description
    Given a goal with description "A1C below 7%" for patient "100"
    When I serialize the goal to FHIR
    Then the FHIR goal description should include "A1C below 7%"
