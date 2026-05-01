@onc
Feature: Provenance _revinclude
  As an ONC-certified EHR system
  FHIR search should support _revinclude=Provenance:target
  So that data provenance is available per 170.315(g)(10)(i)

  ONC 170.315(g)(10)(i) - Standardized API for patient and population services

  Background:
    Given the system is configured for FHIR API access
    And I have a valid SMART token with scope "patient/Patient.read"

  Scenario: Search with _revinclude=Provenance:target includes Provenance entries in Bundle
    Given provenance records exist for patient "1"
    When I request GET "/fhir/Patient?_id=1&_revinclude=Provenance:target" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And the Bundle should contain Provenance entries with search mode "include"

  Scenario: Search without _revinclude does not include Provenance entries
    Given provenance records exist for patient "1"
    When I request GET "/fhir/Patient?_id=1" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Bundle
    And the Bundle should not contain Provenance entries
