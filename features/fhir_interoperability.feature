Feature: FHIR R4 Interoperability
  As a healthcare interoperability system
  I need to exchange patient data in FHIR R4 format
  So that I can integrate with TEFCA, CommonWell, and other health information networks

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex | ssn         | tribal_enrollment |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   | 111-11-1111 | ANLC-12345        |

  Scenario: Retrieve patient as FHIR Patient resource
    When I request patient "1" in FHIR format
    Then I should receive a valid FHIR Patient resource
    And the FHIR resource should have:
      | resourceType | Patient    |
      | id           | 1          |
      | gender       | female     |
      | birthDate    | 1980-05-15 |
    And the FHIR Patient should have an identifier with system "urn:oid:2.16.840.1.113883.4.349"

  Scenario: FHIR Patient includes tribal enrollment extension
    When I request patient "1" in FHIR format
    Then the FHIR Patient should have a tribal enrollment number in the identifiers
    And the tribal enrollment identifier should contain "ANLC-12345"

  Scenario: FHIR Patient supports US Core Profile requirements
    When I request patient "1" in FHIR format
    Then the FHIR Patient should conform to US Core Patient profile
    And the FHIR resource should have required fields:
      | identifier |
      | name       |
      | gender     |
      | birthDate  |

  Scenario: FHIR Patient includes address and telecom
    When I request patient "1" in FHIR format
    Then the FHIR Patient should have an address with state "AK"
    And the FHIR Patient should have a telecom with value "907-555-1234"

  Scenario: FHIR Patient includes SSN identifier
    When I request patient "1" in FHIR format
    Then the FHIR Patient should have an identifier with system "http://hl7.org/fhir/sid/us-ssn"
    And the SSN identifier value should be "111-11-1111"

  Scenario: Round-trip FHIR serialization preserves data
    Given a patient with complete demographics
    When I serialize the patient to FHIR
    And I deserialize the FHIR resource back to a Patient
    Then the patient name should match the original
    And the patient gender should match the original

  Scenario: FHIR content type is application/fhir+json
    When I request patient "1" via the FHIR API
    Then the response content type should be "application/fhir+json"
