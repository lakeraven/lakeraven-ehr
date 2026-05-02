Feature: Coverage FHIR resource
  As a healthcare system
  I need to represent patient insurance coverage as FHIR resources
  So that payer coordination and eligibility are interoperable

  # =============================================================================
  # COVERAGE CREATION & VALIDATION
  # =============================================================================

  Scenario: Create a valid Coverage
    Given a coverage with type "medicare_a" for patient "1"
    Then the coverage should be valid

  Scenario: Coverage requires patient reference
    Given a coverage without a patient
    Then the coverage should be invalid
    And there should be a coverage error on "patient_dfn"

  Scenario: Coverage requires coverage type
    Given a coverage without a type for patient "1"
    Then the coverage should be invalid
    And there should be a coverage error on "coverage_type"

  # =============================================================================
  # COVERAGE STATUS
  # =============================================================================

  Scenario: Active coverage within period
    Given a coverage with period from "2025-01-01" to "2027-12-31" for patient "1"
    Then the coverage should be active

  Scenario: Expired coverage
    Given a coverage with period from "2020-01-01" to "2020-12-31" for patient "1"
    Then the coverage should be expired

  Scenario: Coverage with no end date is active
    Given a coverage with start date "2025-01-01" and no end date for patient "1"
    Then the coverage should be active

  # =============================================================================
  # COVERAGE TYPES
  # =============================================================================

  Scenario: Medicare Part A coverage
    Given a coverage with type "medicare_a" for patient "1"
    Then the coverage type display should include "Medicare"

  Scenario: Medicaid coverage
    Given a coverage with type "medicaid" for patient "1"
    Then the coverage type display should include "Medicaid"

  Scenario: Private insurance coverage
    Given a coverage with type "private_insurance" for patient "1"
    Then the coverage type display should include "Private"

  # =============================================================================
  # FHIR SERIALIZATION
  # =============================================================================

  Scenario: FHIR Coverage includes resourceType
    Given a coverage with type "medicare_a" for patient "1"
    When I serialize the coverage to FHIR
    Then the FHIR resourceType should be "Coverage"

  Scenario: FHIR Coverage includes beneficiary reference
    Given a coverage with type "medicare_a" for patient "123"
    When I serialize the coverage to FHIR
    Then the FHIR beneficiary reference should be "Patient/123"

  Scenario: FHIR Coverage includes status
    Given a coverage with type "medicare_a" and status "active" for patient "1"
    When I serialize the coverage to FHIR
    Then the FHIR coverage status should be "active"

  Scenario: FHIR Coverage includes period
    Given a coverage with period from "2024-01-01" to "2024-12-31" for patient "1"
    When I serialize the coverage to FHIR
    Then the FHIR period start should be "2024-01-01"
    And the FHIR period end should be "2024-12-31"
