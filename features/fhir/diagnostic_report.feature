# frozen_string_literal: true

Feature: DiagnosticReport FHIR resource
  As a healthcare system
  I need to represent diagnostic reports
  So that lab and radiology results are interoperable

  Scenario: Create a valid diagnostic report
    Given a diagnostic report with code "CBC" for patient "100"
    Then the diagnostic report should be valid

  Scenario: Diagnostic report requires patient
    Given a diagnostic report without a patient
    Then the diagnostic report should be invalid

  Scenario: Diagnostic report requires code display
    Given a diagnostic report without a code for patient "100"
    Then the diagnostic report should be invalid

  Scenario: Lab diagnostic report
    Given a lab diagnostic report with code "CBC" and LOINC "58410-2" for patient "100"
    Then the diagnostic report should be valid

  Scenario: Radiology diagnostic report
    Given a radiology diagnostic report with code "Chest X-Ray" for patient "100"
    Then the diagnostic report should be valid

  Scenario: FHIR DiagnosticReport includes resourceType
    Given a diagnostic report with code "CBC" for patient "100"
    When I serialize the diagnostic report to FHIR
    Then the FHIR resourceType should be "DiagnosticReport"

  Scenario: FHIR DiagnosticReport includes subject
    Given a diagnostic report with code "CBC" for patient "100"
    When I serialize the diagnostic report to FHIR
    Then the FHIR subject reference should include "100"

  Scenario: FHIR DiagnosticReport includes status
    Given a diagnostic report with code "CBC" for patient "100"
    When I serialize the diagnostic report to FHIR
    Then the FHIR diagnostic report status should be "final"

  Scenario: FHIR DiagnosticReport includes category
    Given a lab diagnostic report with code "CBC" and LOINC "58410-2" for patient "100"
    When I serialize the diagnostic report to FHIR
    Then the FHIR diagnostic report category should be "LAB"
