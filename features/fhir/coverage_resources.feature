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

  Scenario: FHIR Coverage serialization includes member id and plan class
    Given a coverage with type "private_insurance" for patient "1"
    And the coverage payor name is "Blue Cross"
    And the coverage plan name is "PPO Gold"
    And the coverage member id is "BC-SYNTH-0001"
    And the coverage period starts on "2024-01-01"
    When I serialize the coverage to FHIR
    Then the FHIR Coverage subscriber id should be "BC-SYNTH-0001"
    And the FHIR Coverage plan class value should be "BC-SYNTH-0001"
    And the FHIR Coverage plan class name should be "PPO Gold"
