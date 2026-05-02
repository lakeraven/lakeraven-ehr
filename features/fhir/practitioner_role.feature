Feature: PractitionerRole FHIR resource
  As a healthcare system
  I need to represent practitioner roles and specialties
  So that provider capabilities are interoperable

  Scenario: Create a valid practitioner role
    Given a practitioner role with role "doctor" for practitioner "101"
    Then the practitioner role should be valid

  Scenario: Practitioner role includes specialty
    Given a practitioner role with specialty "Cardiology" for practitioner "101"
    Then the specialty should be "Cardiology"

  Scenario: Active practitioner role
    Given an active practitioner role for practitioner "101"
    Then the practitioner role should be active

  Scenario: FHIR PractitionerRole includes resourceType
    Given a practitioner role with role "PCP" for practitioner "101"
    When I serialize the practitioner role to FHIR
    Then the FHIR resourceType should be "PractitionerRole"

  Scenario: FHIR PractitionerRole includes practitioner reference
    Given a practitioner role with role "PCP" for practitioner "101"
    When I serialize the practitioner role to FHIR
    Then the FHIR practitioner reference should include "101"

  Scenario: FHIR PractitionerRole includes specialty
    Given a practitioner role with specialty "Cardiology" for practitioner "101"
    When I serialize the practitioner role to FHIR
    Then the FHIR specialty should include "Cardiology"
