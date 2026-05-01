@onc
Feature: Vital Signs US Core Compliance
  As an ONC-certified EHR system
  Vital signs observations should conform to US Core profiles
  So that vital sign data is interoperable per § 170.315(g)(10)(i)

  ONC § 170.315(g)(10)(i) - Standardized API for patient and population services

  Background:
    Given the system is configured for FHIR API access
    And I have a valid SMART token with scope "patient/Observation.read"
    And a test patient exists with vital signs on file

  Scenario: Blood pressure observation uses component pattern
    When I request GET "/fhir/Observation?patient=1&category=vital-signs&code=85354-9" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And the first observation should have systolic and diastolic components

  Scenario: Vital signs observations include proper UCUM units
    When I request GET "/fhir/Observation?patient=1&category=vital-signs" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And vital sign observations should include UCUM unit codes

  Scenario: Vital signs observations include category coding with vital-signs
    When I request GET "/fhir/Observation?patient=1&category=vital-signs" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And each observation entry should have category "vital-signs"

  Scenario: Blood pressure profile URL is us-core-blood-pressure
    When I request GET "/fhir/Observation?patient=1&category=vital-signs&code=85354-9" with the Bearer token
    Then the response status should be 200
    And the first observation should have profile "http://hl7.org/fhir/us/core/StructureDefinition/us-core-blood-pressure"

  Scenario: Each vital type has its specific US Core profile
    When I request GET "/fhir/Observation?patient=1&category=vital-signs" with the Bearer token
    Then the response status should be 200
    And each vital sign observation should reference a US Core profile
