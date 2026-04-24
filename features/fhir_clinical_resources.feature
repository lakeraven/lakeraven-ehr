Feature: FHIR Clinical Resource API
  As a healthcare interoperability system
  I need to access patient clinical data via FHIR R4 endpoints
  So that I can meet ONC § 170.315(g)(10) requirements for patient data API access

  Background:
    Given I am authenticated with SMART-on-FHIR
    And patient "1" has clinical data in the system

  # ===========================================================================
  # AllergyIntolerance
  # ===========================================================================

  Scenario: Search AllergyIntolerance by patient returns FHIR Bundle
    When I request GET "/lakeraven-ehr/AllergyIntolerance" with params:
      | patient | 1 |
    Then the response status should be 200
    And the response should be valid FHIR JSON
    And the response should be a FHIR Bundle
    And the Bundle should have type "searchset"

  Scenario: AllergyIntolerance search without patient returns 400
    When I request GET "/lakeraven-ehr/AllergyIntolerance"
    Then the response status should be 400
    And the response resourceType should be "OperationOutcome"

  Scenario: AllergyIntolerance show returns 404 for unknown ID
    When I request GET "/lakeraven-ehr/AllergyIntolerance/unknown-id"
    Then the response status should be 404
    And the response resourceType should be "OperationOutcome"

  # ===========================================================================
  # Condition
  # ===========================================================================

  Scenario: Search Condition by patient returns FHIR Bundle
    When I request GET "/lakeraven-ehr/Condition" with params:
      | patient | 1 |
    Then the response status should be 200
    And the response should be valid FHIR JSON
    And the response should be a FHIR Bundle
    And the Bundle should have type "searchset"

  Scenario: Condition supports category filter
    When I request GET "/lakeraven-ehr/Condition" with params:
      | patient  | 1                 |
      | category | problem-list-item |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  Scenario: Condition search without patient returns 400
    When I request GET "/lakeraven-ehr/Condition"
    Then the response status should be 400
    And the response resourceType should be "OperationOutcome"

  Scenario: Condition show returns 404 for unknown ID
    When I request GET "/lakeraven-ehr/Condition/unknown-id"
    Then the response status should be 404
    And the response resourceType should be "OperationOutcome"

  # ===========================================================================
  # MedicationRequest
  # ===========================================================================

  Scenario: Search MedicationRequest by patient returns FHIR Bundle
    When I request GET "/lakeraven-ehr/MedicationRequest" with params:
      | patient | 1 |
    Then the response status should be 200
    And the response should be valid FHIR JSON
    And the response should be a FHIR Bundle
    And the Bundle should have type "searchset"

  Scenario: MedicationRequest supports status filter
    When I request GET "/lakeraven-ehr/MedicationRequest" with params:
      | patient | 1      |
      | status  | active |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  Scenario: MedicationRequest search without patient returns 400
    When I request GET "/lakeraven-ehr/MedicationRequest"
    Then the response status should be 400
    And the response resourceType should be "OperationOutcome"

  Scenario: MedicationRequest show returns 404 for unknown ID
    When I request GET "/lakeraven-ehr/MedicationRequest/unknown-id"
    Then the response status should be 404
    And the response resourceType should be "OperationOutcome"

  # ===========================================================================
  # Observation
  # ===========================================================================

  Scenario: Search Observation by patient returns FHIR Bundle
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient | 1 |
    Then the response status should be 200
    And the response should be valid FHIR JSON
    And the response should be a FHIR Bundle
    And the Bundle should have type "searchset"

  Scenario: Observation supports category filter for vital-signs
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient  | 1           |
      | category | vital-signs |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  Scenario: Observation supports category filter for laboratory
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient  | 1          |
      | category | laboratory |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  Scenario: Observation search without patient returns 400
    When I request GET "/lakeraven-ehr/Observation"
    Then the response status should be 400
    And the response resourceType should be "OperationOutcome"

  Scenario: Observation show returns 404 for unknown ID
    When I request GET "/lakeraven-ehr/Observation/unknown-id"
    Then the response status should be 404
    And the response resourceType should be "OperationOutcome"

  # ===========================================================================
  # Content Negotiation (applies to all clinical resources)
  # ===========================================================================

  Scenario: Clinical resource endpoints return FHIR JSON content type
    When I request GET "/lakeraven-ehr/AllergyIntolerance" with params:
      | patient | 1 |
    Then the response status should be 200
    And the response content type should include "application/fhir+json"

  Scenario: Clinical resource endpoints accept Patient/ prefix in patient param
    When I request GET "/lakeraven-ehr/AllergyIntolerance" with params:
      | patient | Patient/1 |
    Then the response status should be 200
    And the response should be a FHIR Bundle
