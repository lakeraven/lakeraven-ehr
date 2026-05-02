Feature: Location FHIR resource
  As a healthcare system
  I need to represent facility locations
  So that clinic and department data is interoperable

  Scenario: Create a valid location
    Given a location with name "Primary Care Clinic"
    Then the location should be valid

  Scenario: Location requires name
    Given a location without a name
    Then the location should be invalid

  Scenario: Location includes abbreviation
    Given a location with name "Primary Care Clinic" and abbreviation "PCC"
    Then the abbreviation should be "PCC"

  Scenario: FHIR Location includes resourceType
    Given a location with name "Primary Care Clinic"
    When I serialize the location to FHIR
    Then the FHIR resourceType should be "Location"

  Scenario: FHIR Location includes name
    Given a location with name "Primary Care Clinic"
    When I serialize the location to FHIR
    Then the FHIR location name should be "Primary Care Clinic"

  Scenario: FHIR Location includes status
    Given a location with name "PCC" and status "active"
    When I serialize the location to FHIR
    Then the FHIR location status should be "active"
