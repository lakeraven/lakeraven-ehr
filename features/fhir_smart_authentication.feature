Feature: FHIR SMART Authentication
  As an ONC-certified EHR system
  FHIR endpoints should require SMART on FHIR authentication
  So that patient data is protected per § 170.315(g)(10)

  Background:
    Given the system is configured for FHIR API access

  Scenario: Unauthenticated request to FHIR endpoint is rejected
    When I request GET "/lakeraven-ehr/Observation?patient=1" without a Bearer token
    Then the response status should be 401
    And the response should be a FHIR OperationOutcome with code "login"

  Scenario: Authenticated request with valid read scope returns data
    Given I have a valid SMART token with scope "patient/Observation.read"
    When I request GET "/lakeraven-ehr/Observation" with the Bearer token and params:
      | patient | 1 |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  Scenario: Token with wrong resource scope is forbidden
    Given I have a valid SMART token with scope "patient/MedicationRequest.read"
    When I request GET "/lakeraven-ehr/Observation" with the Bearer token and params:
      | patient | 1 |
    Then the response status should be 403
    And the response should be a FHIR OperationOutcome with code "forbidden"

  Scenario: Wildcard patient scope grants read access
    Given I have a valid SMART token with scope "patient/*.read"
    When I request GET "/lakeraven-ehr/AllergyIntolerance" with the Bearer token and params:
      | patient | 1 |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  Scenario: System-scoped token can access clinical resources
    Given I have a valid SMART token with scope "system/Observation.read"
    When I request GET "/lakeraven-ehr/Observation" with the Bearer token and params:
      | patient | 1 |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  Scenario: User-scoped token can access clinical resources
    Given I have a valid SMART token with scope "user/Condition.read"
    When I request GET "/lakeraven-ehr/Condition" with the Bearer token and params:
      | patient | 1 |
    Then the response status should be 200
    And the response should be a FHIR Bundle

  Scenario: Unauthenticated show request is rejected
    When I request GET "/lakeraven-ehr/Observation/1" without a Bearer token
    Then the response status should be 401
    And the response should be a FHIR OperationOutcome with code "login"

  Scenario: Multiple scopes grant combined access
    Given I have a valid SMART token with scope "patient/Observation.read patient/Condition.read"
    When I request GET "/lakeraven-ehr/Condition" with the Bearer token and params:
      | patient | 1 |
    Then the response status should be 200
    And the response should be a FHIR Bundle
