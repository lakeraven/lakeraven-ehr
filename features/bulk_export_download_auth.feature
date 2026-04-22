Feature: Bulk Export Download Authentication
  As an ONC-certified EHR system
  Bulk export download, status, and cancel endpoints should require SMART authentication
  And enforce client ownership so one client cannot access another's exports
  Per § 170.315(g)(10)

  Background:
    Given the system is configured for FHIR API access

  Scenario: Download without authentication is rejected
    When I request GET "/fhir/bulk-export-files/1/Patient.ndjson" without a Bearer token
    Then the response status should be 401
    And the response should be a FHIR OperationOutcome with code "login"

  Scenario: Status check without authentication is rejected
    When I request GET "/fhir/$export-status/1" without a Bearer token
    Then the response status should be 401
    And the response should be a FHIR OperationOutcome with code "login"

  Scenario: Cancel without authentication is rejected
    When I request DELETE "/fhir/$export-status/1" without a Bearer token
    Then the response status should be 401
    And the response should be a FHIR OperationOutcome with code "login"

  Scenario: Download with patient-only scope is forbidden
    Given I have a valid SMART token with scope "patient/Observation.read"
    When I request GET "/fhir/bulk-export-files/1/Patient.ndjson" with the Bearer token
    Then the response status should be 403

  Scenario: Status check with valid system scope but wrong client is forbidden
    Given I have a valid SMART token with scope "system/*.read"
    And a bulk export exists for a different client
    When I check the status of the other client's export with my Bearer token
    Then the response status should be 403
    And the response should contain "different client"
