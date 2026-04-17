Feature: Practitioner clinical identity model
  As a clinical application
  I need a Practitioner model that stores provider demographics, formats names,
  and serializes to FHIR R4 with US Core extensions
  So that I can interoperate with EHRs per ONC § 170.315(g)(10)

  # ===========================================================================
  # ATTRIBUTES AND COMPOSITE FIELD SYNCING
  # ===========================================================================

  Scenario: Create a practitioner from VistA name format
    Given a practitioner with name "DOE,JOHN A"
    Then the practitioner last_name should be "Doe"
    And the practitioner first_name should be "John"
    And the practitioner display_name should be "John A Doe"
    And the practitioner formal_name should be "Doe, John A"

  Scenario: Create a practitioner from separate name parts
    Given a practitioner with first_name "Jane" and last_name "Smith"
    Then the practitioner name should be "Smith,Jane"
    And the practitioner display_name should be "Jane Smith"

  Scenario: Create a practitioner from a single-token name (no comma)
    Given a practitioner with name "ADMIN"
    Then the practitioner display_name should be "ADMIN"
    And the practitioner first_name should be blank
    And the practitioner last_name should be blank

  # ===========================================================================
  # FHIR SERIALIZATION — US Core Practitioner
  # ===========================================================================

  Scenario: to_fhir emits a US Core Practitioner resource
    Given a practitioner with name "DOE,JOHN" and npi "1234567890"
    When I serialize the practitioner to FHIR
    Then the FHIR resourceType should be "Practitioner"
    And the FHIR meta profile should include the US Core Practitioner profile
    And the FHIR name family should be "DOE"
    And the FHIR name given should include "JOHN"

  Scenario: to_fhir maps gender to FHIR administrative-gender
    Given a practitioner with name "DOE,JOHN" and gender "M"
    When I serialize the practitioner to FHIR
    Then the FHIR gender should be "male"

  Scenario: to_fhir includes NPI identifier
    Given a practitioner with name "DOE,JOHN" and npi "1234567890"
    When I serialize the practitioner to FHIR
    Then the FHIR identifiers should include system "http://hl7.org/fhir/sid/us-npi" with value "1234567890"

  Scenario: to_fhir includes IEN identifier
    Given a practitioner with ien 42 and name "DOE,JOHN"
    When I serialize the practitioner to FHIR
    Then the FHIR identifiers should include system "http://ihs.gov/rpms/provider-id" with value "42"

  Scenario: to_fhir includes specialty as qualification
    Given a practitioner with name "DOE,JOHN" and specialty "Family Medicine"
    When I serialize the practitioner to FHIR
    Then the FHIR qualifications should include "Family Medicine"

  Scenario: to_fhir includes telecom
    Given a practitioner with name "DOE,JOHN" and phone "555-0100"
    When I serialize the practitioner to FHIR
    Then the FHIR telecom value should be "555-0100"

  # ===========================================================================
  # FHIR DESERIALIZATION
  # ===========================================================================

  Scenario: from_fhir builds a Practitioner from a FHIR resource
    Given a FHIR Practitioner resource with family "DOE" given "JOHN" npi "1234567890"
    When I build a practitioner from the FHIR resource
    Then the practitioner name should be "DOE,JOHN"
    And the practitioner last_name should be "Doe"
    And the practitioner first_name should be "John"
    And the practitioner npi should be "1234567890"

  Scenario: from_fhir round-trips IEN and qualifications
    Given a FHIR Practitioner resource with ien "42" specialty "Family Medicine" and provider_class "Physician"
    When I build a practitioner from the FHIR resource
    Then the practitioner ien should be 42
    And the practitioner specialty should be "Family Medicine"
    And the practitioner provider_class should be "Physician"
