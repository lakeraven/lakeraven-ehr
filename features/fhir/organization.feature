Feature: Organization FHIR resource
  As a healthcare system
  I need to represent healthcare organizations
  So that facility and provider organization data is interoperable

  Scenario: Create a valid organization
    Given an organization with name "Alaska Native Medical Center"
    Then the organization should be valid

  Scenario: Organization requires name
    Given an organization without a name
    Then the organization should be invalid

  Scenario: Organization includes station number
    Given an organization with name "ANMC" and station number "463"
    Then the station number should be "463"

  Scenario: FHIR Organization includes resourceType
    Given an organization with name "ANMC"
    When I serialize the organization to FHIR
    Then the FHIR resourceType should be "Organization"

  Scenario: FHIR Organization includes name
    Given an organization with name "Alaska Native Medical Center"
    When I serialize the organization to FHIR
    Then the FHIR organization name should be "Alaska Native Medical Center"

  Scenario: FHIR Organization includes identifiers
    Given an organization with name "ANMC" and station number "463"
    When I serialize the organization to FHIR
    Then the FHIR identifiers should include station number "463"
