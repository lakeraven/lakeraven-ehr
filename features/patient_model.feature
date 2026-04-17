Feature: Patient clinical identity model
  As a clinical application
  I need a Patient model that stores demographics, formats names, and
  serializes to FHIR R4 with US Core + IHS extensions
  So that I can interoperate with EHRs per ONC § 170.315(g)(10)

  # ===========================================================================
  # ATTRIBUTES AND COMPOSITE FIELD SYNCING
  # ===========================================================================

  Scenario: Create a patient from VistA name format
    Given a patient with name "DOE,JOHN A"
    Then the patient last_name should be "Doe"
    And the patient first_name should be "John"
    And the patient display_name should be "John A Doe"
    And the patient formal_name should be "Doe, John A"

  Scenario: Create a patient from separate name parts
    Given a patient with first_name "Jane" and last_name "Smith"
    Then the patient name should be "Smith,Jane"
    And the patient display_name should be "Jane Smith"

  Scenario: Patient syncs dob and born_on
    Given a patient with dob "1980-01-15"
    Then the patient born_on should be "1980-01-15"

  # ===========================================================================
  # FHIR SERIALIZATION — US Core Patient
  # ===========================================================================

  Scenario: to_fhir emits a US Core Patient resource
    Given a patient with name "DOE,JOHN" and dob "1980-01-15" and sex "M"
    When I serialize the patient to FHIR
    Then the FHIR resourceType should be "Patient"
    And the FHIR gender should be "male"
    And the FHIR birthDate should be "1980-01-15"
    And the FHIR name family should be "DOE"
    And the FHIR name given should include "JOHN"

  Scenario: to_fhir includes DFN and SSN identifiers
    Given a patient with dfn 12345 and ssn "123-45-6789"
    When I serialize the patient to FHIR
    Then the FHIR identifiers should include system "urn:oid:2.16.840.1.113883.4.349" with value "12345"
    And the FHIR identifiers should include system "http://hl7.org/fhir/sid/us-ssn" with value "123-45-6789"

  Scenario: to_fhir includes address and telecom
    Given a patient with address "123 Main St" city "Toppenish" state "WA" zip "98948" phone "555-1234"
    When I serialize the patient to FHIR
    Then the FHIR address line should be "123 Main St"
    And the FHIR address city should be "Toppenish"
    And the FHIR telecom value should be "555-1234"

  # ===========================================================================
  # FHIR EXTENSIONS — US Core Race / Ethnicity
  # ===========================================================================

  Scenario: to_fhir includes US Core race extension
    Given a patient with race "AMERICAN INDIAN OR ALASKA NATIVE"
    When I serialize the patient to FHIR
    Then the FHIR extensions should include a US Core race extension
    And the race ombCategory code should be "1002-5"

  Scenario: to_fhir includes US Core ethnicity extension (default unknown)
    Given a patient with name "DOE,JOHN" and sex "M"
    When I serialize the patient to FHIR
    Then the FHIR extensions should include a US Core ethnicity extension
    And the ethnicity text should be "Unknown"

  # ===========================================================================
  # FHIR EXTENSIONS — IHS Tribal
  # ===========================================================================

  Scenario: to_fhir includes tribal affiliation extension
    Given a patient with tribal_affiliation "Enrolled Member"
    When I serialize the patient to FHIR
    Then the FHIR extensions should include url "https://ihs.gov/fhir/StructureDefinition/tribal-affiliation"

  Scenario: to_fhir includes tribal enrollment number extension
    Given a patient with tribal_enrollment_number "ENR-12345"
    When I serialize the patient to FHIR
    Then the FHIR extensions should include url "https://ihs.gov/fhir/StructureDefinition/tribal-enrollment-number"

  # ===========================================================================
  # FHIR EXTENSIONS — SOGI (USCDI v3)
  # ===========================================================================

  Scenario: to_fhir includes sexual orientation extension
    Given a patient with sexual_orientation "Straight or heterosexual"
    When I serialize the patient to FHIR
    Then the FHIR extensions should include url "http://hl7.org/fhir/StructureDefinition/patient-sexualOrientation"

  Scenario: to_fhir includes gender identity extension
    Given a patient with gender_identity "Identifies as male"
    When I serialize the patient to FHIR
    Then the FHIR extensions should include url "http://hl7.org/fhir/StructureDefinition/patient-genderIdentity"

  # ===========================================================================
  # FHIR DESERIALIZATION
  # ===========================================================================

  Scenario: from_fhir_attributes extracts demographics
    Given a FHIR Patient resource with family "DOE" given "JOHN" gender "male" birthDate "1980-01-15"
    When I extract attributes from the FHIR resource
    Then the extracted name should be "DOE,JOHN"
    And the extracted sex should be "M"
    And the extracted dob should be "1980-01-15"
