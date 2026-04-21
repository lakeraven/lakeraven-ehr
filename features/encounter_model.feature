Feature: Encounter clinical visit model
  As a clinical application
  I need an Encounter model that stores visit data and
  serializes to FHIR R4 with US Core extensions
  So that I can interoperate with EHRs per ONC § 170.315(g)(10)

  # ===========================================================================
  # ATTRIBUTES AND STATUS
  # ===========================================================================

  Scenario: Create an encounter with core attributes
    Given an encounter with status "finished" and class_code "AMB"
    Then the encounter status should be "finished"
    And the encounter class_code should be "AMB"
    And the encounter status_display should be "Finished"
    And the encounter class_display should be "Ambulatory"

  Scenario: Status predicates
    Given an encounter with status "in-progress" and class_code "AMB"
    Then the encounter should be in_progress
    And the encounter should not be finished

  Scenario: Class predicates
    Given an encounter with status "finished" and class_code "EMER"
    Then the encounter should be emergency
    And the encounter should not be ambulatory

  Scenario: Encounter validates status and class_code
    Given an encounter with status "bogus" and class_code "AMB"
    Then the encounter should not be valid

  # ===========================================================================
  # FHIR SERIALIZATION — US Core Encounter
  # ===========================================================================

  Scenario: to_fhir emits a US Core Encounter resource
    Given an encounter with status "finished" and class_code "AMB" and period "2024-01-15T09:00" to "2024-01-15T10:00"
    When I serialize the encounter to FHIR
    Then the FHIR resourceType should be "Encounter"
    And the FHIR meta profile should include the US Core Encounter profile
    And the FHIR status should be "finished"
    And the FHIR class code should be "AMB"
    And the FHIR class system should be "http://terminology.hl7.org/CodeSystem/v3-ActCode"
    And the FHIR period start should be "2024-01-15T09:00"
    And the FHIR period end should be "2024-01-15T10:00"

  Scenario: to_fhir includes type when present
    Given an encounter with status "finished" class_code "AMB" type_code "99213" type_display "Office visit, established patient, moderate"
    When I serialize the encounter to FHIR
    Then the FHIR type text should be "Office visit, established patient, moderate"

  Scenario: to_fhir includes reason when present
    Given an encounter with status "finished" class_code "AMB" reason_code "R10.9" reason_display "Unspecified abdominal pain"
    When I serialize the encounter to FHIR
    Then the FHIR reasonCode text should be "Unspecified abdominal pain"

  Scenario: to_fhir includes patient reference
    Given an encounter with status "finished" class_code "AMB" and patient_identifier "pt_01H8X"
    When I serialize the encounter to FHIR
    Then the FHIR subject reference should be "Patient/pt_01H8X"

  Scenario: to_fhir includes practitioner participant
    Given an encounter with status "finished" class_code "AMB" and practitioner_identifier "prov_01H8X"
    When I serialize the encounter to FHIR
    Then the FHIR participant individual reference should be "Practitioner/prov_01H8X"

  # ===========================================================================
  # FHIR DESERIALIZATION
  # ===========================================================================

  Scenario: from_fhir builds an Encounter from a FHIR resource
    Given a FHIR Encounter resource with status "finished" class "AMB" and period "2024-01-15T09:00" to "2024-01-15T10:00"
    When I build an encounter from the FHIR resource
    Then the encounter status should be "finished"
    And the encounter class_code should be "AMB"
