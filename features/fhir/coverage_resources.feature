Feature: Coverage FHIR resources for payer coordination
  As a healthcare system
  I need Coverage resources with complete FHIR fields
  So that payer coordination and PRC workflows interoperate

  Scenario: Create Coverage from Medicaid enrollment response
    Given a Medicaid enrollment eligibility response for patient "12345"
    When I build coverage from the eligibility response
    Then the coverage should be valid
    And the coverage payor should be "Medicaid"
    And the coverage type should be "medicaid"

  Scenario: FHIR Coverage serialization puts member id on MB identifier not subscriberId
    Given a coverage with type "private_insurance" for patient "1"
    And the coverage payor name is "Blue Cross"
    And the coverage plan name is "PPO Gold"
    And the coverage member id is "BC-SYNTH-0001"
    And the coverage period starts on "2024-01-01"
    When I serialize the coverage to FHIR
    Then the FHIR Coverage subscriber id should be absent
    And the FHIR Coverage member identifier value should be "BC-SYNTH-0001"
    And the FHIR Coverage plan class value should be "PPO Gold"
    And the FHIR Coverage plan class name should be "PPO Gold"

  Scenario: FHIR Coverage class codings use HL7 coverage-class system
    Given a coverage with type "private_insurance" for patient "1"
    And the coverage group id is "GRP-SYNTH-01"
    And the coverage plan name is "PPO Gold"
    When I serialize the coverage to FHIR
    Then each FHIR Coverage class type coding system should be "http://terminology.hl7.org/CodeSystem/coverage-class"

  Scenario: FHIR Coverage member identifier uses v2-0203 MB coding
    Given a coverage with type "private_insurance" for patient "1"
    And the coverage subscriber id is "BC-SUB-9000"
    And the coverage member id is "BC-SYNTH-0001"
    When I serialize the coverage to FHIR
    Then the FHIR Coverage subscriber id should be "BC-SUB-9000"
    And the FHIR Coverage member identifier type system should be "http://terminology.hl7.org/CodeSystem/v2-0203"
    And the FHIR Coverage member identifier type code should be "MB"
    And the FHIR Coverage member identifier value should be "BC-SYNTH-0001"

  Scenario: FHIR Coverage type uses local coverage-type CodeSystem
    Given a coverage with type "medicare_b" for patient "1"
    When I serialize the coverage to FHIR
    Then the FHIR Coverage type coding system should be "urn:lakeraven:fhir:CodeSystem:coverage-type"
    And the FHIR Coverage type coding code should be "medicare_b"
    And the FHIR Coverage type coding display should be present

  Scenario Outline: PRC-internal coverage status maps to FHIR R4 fm-status and extension
    Given a coverage with type "medicaid" and status "<prc_status>" for patient "1"
    When I serialize the coverage to FHIR
    Then the FHIR coverage status should be "<fhir_status>"
    And the coverage model status should be "<prc_status>"
    And the FHIR Coverage PRC status extension should be "<prc_status>"

    Examples:
      | prc_status   | fhir_status |
      | exhausted    | cancelled   |
      | not_enrolled | cancelled   |
      | denied       | cancelled   |
      | pending      | draft       |
