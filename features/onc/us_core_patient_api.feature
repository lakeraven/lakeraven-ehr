@onc
Feature: US Core Patient API
  As an ONC-certified EHR system
  The FHIR Patient API should conform to US Core profile requirements
  So that patient demographics are interoperable per 170.315(g)(10)(i)

  ONC 170.315(g)(10)(i) - Standardized API for patient and population services

  Background:
    Given the system is configured for FHIR API access
    And I have a valid SMART token with scope "patient/Patient.read"

  Scenario: Search by _id returns patient with US Core profile in meta
    When I request GET "/fhir/Patient?_id=1" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And the Bundle should contain at least 1 entries
    And the first patient entry should include US Core Patient profile in meta

  Scenario: Search by name returns matching patients in Bundle
    When I request GET "/fhir/Patient?name=Anderson" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And each entry should have resourceType "Patient"

  Scenario: Search by name and birthdate combination works
    When I request GET "/fhir/Patient?name=Anderson&birthdate=1980-05-15" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And the Bundle should contain at least 1 entries

  Scenario: Search by name and gender combination works
    When I request GET "/fhir/Patient?name=Anderson&gender=female" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And the Bundle should contain at least 1 entries

  Scenario: Search by identifier with system|value format works
    When I request GET "/fhir/Patient?identifier=http://hl7.org/fhir/sid/us-ssn|111-11-1111" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And the Bundle should contain at least 1 entries

  Scenario: Patient resource includes US Core race extension with ombCategory coding
    When I request GET "/fhir/Patient?_id=1" with the Bearer token
    Then the response status should be 200
    And the first patient entry should include US Core race extension
    And the race extension should contain an ombCategory coding

  Scenario: Patient resource includes US Core ethnicity extension
    When I request GET "/fhir/Patient?_id=1" with the Bearer token
    Then the response status should be 200
    And the first patient entry should include US Core ethnicity extension

  Scenario: Show returns 403 for patient outside SMART context
    When I request GET "/fhir/Patient/999999" with the Bearer token
    Then the response status should be 403
    And the response should be a FHIR OperationOutcome with code "forbidden"
