Feature: RelatedPerson FHIR resource
  As a healthcare system
  I need to represent patient contacts and advocates
  So that proxy access and emergency contacts are interoperable

  Scenario: Create a valid related person
    Given a related person with relationship "parent" for patient "1"
    Then the related person should be valid

  Scenario: Related person requires patient
    Given a related person without a patient
    Then the related person should be invalid

  Scenario: Related person requires name
    Given a related person without a name for patient "1"
    Then the related person should be invalid

  Scenario: Parent relationship
    Given a related person with relationship "parent" for patient "1"
    Then the relationship display should include "Parent"

  Scenario: Spouse relationship
    Given a related person with relationship "spouse" for patient "1"
    Then the relationship display should include "Spouse"

  Scenario: Active related person
    Given an active related person for patient "1"
    Then the related person should be active

  Scenario: Inactive related person
    Given an inactive related person for patient "1"
    Then the related person should not be active

  Scenario: Related person within period
    Given a related person with period from "2025-01-01" to "2027-12-31" for patient "1"
    Then the related person should be within period

  Scenario: Related person outside period
    Given a related person with period from "2020-01-01" to "2020-12-31" for patient "1"
    Then the related person should not be within period

  Scenario: FHIR RelatedPerson includes resourceType
    Given a related person with relationship "parent" for patient "1"
    When I serialize the related person to FHIR
    Then the FHIR resourceType should be "RelatedPerson"

  Scenario: FHIR RelatedPerson includes patient reference
    Given a related person with relationship "parent" for patient "123"
    When I serialize the related person to FHIR
    Then the FHIR patient reference should include "123"

  Scenario: FHIR RelatedPerson includes relationship
    Given a related person with relationship "parent" for patient "1"
    When I serialize the related person to FHIR
    Then the FHIR relationship should be present

  Scenario: FHIR RelatedPerson includes name
    Given a related person named "Jane Doe" with relationship "parent" for patient "1"
    When I serialize the related person to FHIR
    Then the FHIR name should include "Jane"
