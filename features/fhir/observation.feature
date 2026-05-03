# frozen_string_literal: true

Feature: Observation FHIR resource
  As a healthcare system
  I need to represent clinical observations
  So that vital signs and lab data is interoperable

  Scenario: Vital sign observation
    Given a vital sign observation with code "8867-4" and value "72" for patient "100"
    Then the observation should be a vital sign

  Scenario: Laboratory observation
    Given a laboratory observation with code "2339-0" and value "95" for patient "100"
    Then the observation should be a laboratory result

  Scenario: SDOH observation
    Given an SDOH observation with code "71802-3" and value "Homeless" for patient "100"
    Then the observation should be an SDOH observation

  Scenario: Blood pressure observation
    Given a blood pressure observation with value "120/80" for patient "100"
    When I serialize the observation to FHIR
    Then the FHIR observation should have systolic and diastolic components

  Scenario: FHIR Observation includes resourceType
    Given a vital sign observation with code "8867-4" and value "72" for patient "100"
    When I serialize the observation to FHIR
    Then the FHIR resourceType should be "Observation"

  Scenario: FHIR Observation includes subject
    Given a vital sign observation with code "8867-4" and value "72" for patient "100"
    When I serialize the observation to FHIR
    Then the FHIR subject reference should include "100"

  Scenario: FHIR Observation includes category
    Given a vital sign observation with code "8867-4" and value "72" for patient "100"
    When I serialize the observation to FHIR
    Then the FHIR observation category should be "vital-signs"

  Scenario: Build observations from vital hashes
    Given vital sign hashes for patient "100" with type "P" value "72" and type "T" value "98.6"
    Then there should be 2 observations
    And the first observation code should be "8867-4"
