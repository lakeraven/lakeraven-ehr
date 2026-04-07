Feature: US Core Patient API
  As a SMART-on-FHIR client
  I need a FHIR R4 Patient read endpoint conforming to US Core
  So that I can interoperate with EHRs per ONC § 170.315(g)(10)(i)

  This feature lays down the FHIR HTTP layer pattern that every
  subsequent resource type will reuse: routes mounted under the
  engine, controllers that read tenant context from request headers,
  serializers that emit US Core conformant JSON, and OperationOutcome
  responses for error cases.

  Background:
    Given the EHR adapter is the in-memory mock
    And the current tenant is "tnt_test"
    And the current facility is "fac_main"
    And the following patients are registered at facility "fac_main":
      | display_name | date_of_birth | gender |
      | DOE,JOHN     | 1980-01-15    | male   |
      | SMITH,JANE   | 1975-06-20    | female |
    And patient "DOE,JOHN" has identifier system "http://hl7.org/fhir/sid/us-ssn" and value "111-11-1111"

  Scenario: GET Patient by opaque identifier returns a US Core Patient resource
    When I GET the FHIR Patient with identifier of "DOE,JOHN"
    Then the response status is 200
    And the response Content-Type is "application/fhir+json"
    And the response body is a FHIR Patient resource
    And the resource id matches the requested identifier
    And the resource meta.profile includes "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"

  Scenario: Patient resource exposes name as FHIR HumanName
    When I GET the FHIR Patient with identifier of "DOE,JOHN"
    Then the response status is 200
    And the resource name has family "DOE"
    And the resource name has given "JOHN"

  Scenario: Patient resource exposes gender and birthDate
    When I GET the FHIR Patient with identifier of "DOE,JOHN"
    Then the resource gender is "male"
    And the resource birthDate is "1980-01-15"

  Scenario: Patient resource includes seeded FHIR Identifiers
    When I GET the FHIR Patient with identifier of "DOE,JOHN"
    Then the resource identifier includes a value of "111-11-1111" with system "http://hl7.org/fhir/sid/us-ssn"

  Scenario: Unknown patient identifier returns 404 OperationOutcome
    When I GET the FHIR Patient with identifier "pt_does_not_exist"
    Then the response status is 404
    And the response Content-Type is "application/fhir+json"
    And the response body is a FHIR OperationOutcome with severity "error" and code "not-found"

  Scenario: Cross-tenant lookup returns 404 OperationOutcome
    Given a patient "OTHER,PERSON" exists in tenant "tnt_other"
    When I GET the FHIR Patient with the tnt_other identifier of "OTHER,PERSON"
    Then the response status is 404

  Scenario: Missing tenant context returns 400 OperationOutcome
    Given the request omits the tenant header
    When I GET the FHIR Patient with identifier of "DOE,JOHN"
    Then the response status is 400
    And the response body is a FHIR OperationOutcome with severity "error" and code "required"
