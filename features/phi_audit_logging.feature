Feature: PHI audit logging
  As a compliance officer
  I need every PHI-touching request logged as a FHIR AuditEvent
  So I can meet HIPAA § 164.312(b) audit requirements

  Background:
    Given the EHR adapter is the in-memory mock
    And the current tenant is "tnt_test"
    And the current facility is "fac_main"
    And the following patients are registered at facility "fac_main":
      | display_name | date_of_birth | gender |
      | DOE,JOHN     | 1980-01-15    | male   |
    And a confidential OAuth client is registered with scopes "system/Patient.read system/AuditEvent.read"

  Scenario: A successful Patient read creates an AuditEvent row
    When I GET the FHIR Patient with identifier of "DOE,JOHN"
    Then the response status is 200
    And a Patient-read AuditEvent row exists for the last request

  Scenario: AuditEvent rows carry only opaque identifiers, no PHI
    When I GET the FHIR Patient with identifier of "DOE,JOHN"
    Then the last AuditEvent row has entity_type "Patient"
    And the last AuditEvent row has an opaque entity_identifier prefixed with "pt_"
    And the last AuditEvent row has no display_name or date_of_birth column

  Scenario: A 404 response produces an AuditEvent with outcome 4
    When I GET the FHIR Patient with identifier "pt_does_not_exist"
    Then the response status is 404
    And the last AuditEvent row has outcome "4"

  Scenario: AuditEvent rows are immutable
    When I GET the FHIR Patient with identifier of "DOE,JOHN"
    Then updating the last AuditEvent row raises a ReadOnly error
    And deleting the last AuditEvent row raises a ReadOnly error

  Scenario: GET /AuditEvent returns a FHIR Bundle of the current tenant's rows
    Given 3 AuditEvent rows exist in the current tenant
    And 1 AuditEvent row exists in another tenant
    When I GET the FHIR AuditEvent endpoint with a valid token
    Then the response status is 200
    And the response body is a FHIR Bundle of type "searchset"
    And the Bundle total is 3
    And no entry in the Bundle belongs to another tenant

  Scenario: GET /AuditEvent requires a Bearer token
    Given 1 AuditEvent row exists in the current tenant
    When I GET the FHIR AuditEvent endpoint without a Bearer token
    Then the response status is 401

  Scenario: GET /AuditEvent requires AuditEvent.read scope
    Given 1 AuditEvent row exists in the current tenant
    When I GET the FHIR AuditEvent endpoint with a token that only has "system/Patient.read" scope
    Then the response status is 403
