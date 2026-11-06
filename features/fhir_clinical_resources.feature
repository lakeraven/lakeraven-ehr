Feature: FHIR Clinical Resource API
  As a healthcare interoperability system
  I need to access patient clinical data via FHIR R4 endpoints
  So that I can meet ONC § 170.315(g)(10) requirements for patient data API access

  # DFN 4 is the demo patient of the pinned RPMS build with the most clinical
  # data (an allergy, problems and vitals). The table is checked against RPMS
  # on a live run and seeded into the mock otherwise.
  Background:
    Given I am authenticated with SMART-on-FHIR for patient "4"
    And these RPMS demo patients:
      | dfn | name             | ssn       | dob        | sex |
      | 4   | DEMO,PATIENT ONE | 666010101 | 2001-01-01 | F   |
    And patient "4" has clinical data in the system

  # ===========================================================================
  # AllergyIntolerance
  # ===========================================================================

  @live
  Scenario: Search AllergyIntolerance by patient returns FHIR Bundle
    When I request GET "/lakeraven-ehr/AllergyIntolerance" with params:
      | patient | 4 |
    Then the response status should be 200
    And the response should be valid FHIR JSON
    And the response should be a FHIR Bundle
    And the Bundle should have type "searchset"

  @live
  Scenario: AllergyIntolerance search without patient returns 400
    When I request GET "/lakeraven-ehr/AllergyIntolerance"
    Then the response status should be 400
    And the response resourceType should be "OperationOutcome"

  @live
  Scenario: AllergyIntolerance show returns 404 for unknown ID
    When I request GET "/lakeraven-ehr/AllergyIntolerance/unknown-id"
    Then the response status should be 404
    And the response resourceType should be "OperationOutcome"

  # ===========================================================================
  # Condition
  # ===========================================================================

  @live
  Scenario: Search Condition by patient returns FHIR Bundle
    When I request GET "/lakeraven-ehr/Condition" with params:
      | patient | 4 |
    Then the response status should be 200
    And the response should be valid FHIR JSON
    And the response should be a FHIR Bundle
    And the Bundle should have type "searchset"

  @live
  Scenario: Condition supports category filter
    When I request GET "/lakeraven-ehr/Condition" with params:
      | patient  | 4                 |
      | category | problem-list-item |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  @live
  Scenario: Condition search without patient returns 400
    When I request GET "/lakeraven-ehr/Condition"
    Then the response status should be 400
    And the response resourceType should be "OperationOutcome"

  @live
  Scenario: Condition show returns 404 for unknown ID
    When I request GET "/lakeraven-ehr/Condition/unknown-id"
    Then the response status should be 404
    And the response resourceType should be "OperationOutcome"

  # ===========================================================================
  # MedicationRequest
  # ===========================================================================

  @live
  Scenario: Search MedicationRequest by patient returns FHIR Bundle
    When I request GET "/lakeraven-ehr/MedicationRequest" with params:
      | patient | 4 |
    Then the response status should be 200
    And the response should be valid FHIR JSON
    And the response should be a FHIR Bundle
    And the Bundle should have type "searchset"

  @live
  Scenario: MedicationRequest supports status filter
    When I request GET "/lakeraven-ehr/MedicationRequest" with params:
      | patient | 4      |
      | status  | active |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  @live
  Scenario: MedicationRequest search without patient returns 400
    When I request GET "/lakeraven-ehr/MedicationRequest"
    Then the response status should be 400
    And the response resourceType should be "OperationOutcome"

  @live
  Scenario: MedicationRequest show returns 404 for unknown ID
    When I request GET "/lakeraven-ehr/MedicationRequest/unknown-id"
    Then the response status should be 404
    And the response resourceType should be "OperationOutcome"

  # ===========================================================================
  # Observation
  # ===========================================================================

  @live
  Scenario: Search Observation by patient returns FHIR Bundle
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient | 4 |
    Then the response status should be 200
    And the response should be valid FHIR JSON
    And the response should be a FHIR Bundle
    And the Bundle should have type "searchset"

  @live
  Scenario: Observation supports category filter for vital-signs
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient  | 4           |
      | category | vital-signs |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  @live
  Scenario: Observation supports category filter for laboratory
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient  | 4          |
      | category | laboratory |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  @live
  Scenario: Observation search without patient returns 400
    When I request GET "/lakeraven-ehr/Observation"
    Then the response status should be 400
    And the response resourceType should be "OperationOutcome"

  @live
  Scenario: Observation show returns 404 for unknown ID
    When I request GET "/lakeraven-ehr/Observation/unknown-id"
    Then the response status should be 404
    And the response resourceType should be "OperationOutcome"

  # ===========================================================================
  # Content Negotiation (applies to all clinical resources)
  # ===========================================================================

  @live
  Scenario: Clinical resource endpoints return FHIR JSON content type
    When I request GET "/lakeraven-ehr/AllergyIntolerance" with params:
      | patient | 4 |
    Then the response status should be 200
    And the response content type should include "application/fhir+json"

  @live
  Scenario: Clinical resource endpoints accept Patient/ prefix in patient param
    When I request GET "/lakeraven-ehr/AllergyIntolerance" with params:
      | patient | Patient/4 |
    Then the response status should be 200
    And the response should be a FHIR Bundle
