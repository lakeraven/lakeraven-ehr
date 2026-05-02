# frozen_string_literal: true

Feature: CareTeam FHIR resource
  As a healthcare system
  I need to represent patient care teams
  So that team composition is interoperable

  Scenario: Create a valid care team
    Given a care team with name "Primary Care Team" for patient "100"
    Then the care team should be valid

  Scenario: Care team requires patient
    Given a care team without a patient
    Then the care team should be invalid

  Scenario: Care team with participants
    Given a care team with name "Primary Care Team" for patient "100"
    And the care team has a participant with duz "201" and role "Primary Care Provider"
    Then the care team should be valid

  Scenario: FHIR CareTeam includes resourceType
    Given a care team with name "Primary Care Team" for patient "100"
    When I serialize the care team to FHIR
    Then the FHIR resourceType should be "CareTeam"

  Scenario: FHIR CareTeam includes subject reference
    Given a care team with name "Primary Care Team" for patient "100"
    When I serialize the care team to FHIR
    Then the FHIR care team subject reference should include "100"

  Scenario: FHIR CareTeam includes participants
    Given a care team with name "Primary Care Team" for patient "100"
    And the care team has a participant with duz "201" and role "PCP"
    When I serialize the care team to FHIR
    Then the FHIR care team should have participants

  Scenario: FHIR CareTeam includes name
    Given a care team with name "Primary Care Team" for patient "100"
    When I serialize the care team to FHIR
    Then the FHIR care team name should be "Primary Care Team"
