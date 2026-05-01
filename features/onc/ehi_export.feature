@onc
Feature: Electronic Health Information Export
  As a patient or authorized user
  I want to export a complete copy of my electronic health information
  So that I can exercise my data portability rights

  ONC § 170.315(b)(10) — Electronic Health Information Export

  Background:
    Given a patient exists with DFN "12345"

  # =============================================================================
  # SINGLE-PATIENT EHI EXPORT
  # =============================================================================

  Scenario: Generate a complete EHI export for a patient
    Given the patient has clinical data for EHI export
    When a single-patient EHI export is requested
    Then the export should complete successfully
    And the export should contain FHIR clinical resources
    And the export should contain audit log entries
    And the export should contain a manifest file

  Scenario: EHI export includes all FHIR resource types
    Given the patient has clinical data for EHI export
    When a single-patient EHI export is requested
    Then the export should include Patient resources
    And the export should include AllergyIntolerance resources
    And the export should include Condition resources
    And the export should include MedicationRequest resources
    And the export should include Observation resources

  # =============================================================================
  # NON-FHIR DATA
  # =============================================================================

  Scenario: EHI export includes audit logs for the patient
    Given the patient has clinical data for EHI export
    And audit events exist for the patient
    When a single-patient EHI export is requested
    Then the export should contain an audit log CSV
    And the audit log should include patient-related events

  Scenario: EHI export includes system configuration relevant to patient care
    Given the patient has clinical data for EHI export
    When a single-patient EHI export is requested
    Then the export should contain a configuration summary
    And the configuration summary should document data sources

  # =============================================================================
  # EXPORT MANIFEST (CCG REQUIREMENT)
  # =============================================================================

  Scenario: EHI export manifest documents contents and format
    Given the patient has clinical data for EHI export
    When a single-patient EHI export is requested
    Then the manifest should list all included files
    And the manifest should describe the export format
    And the manifest should include the export timestamp
    And the manifest should reference ONC certification criterion

  # =============================================================================
  # EXPORT FORMATS
  # =============================================================================

  Scenario: EHI export produces NDJSON for FHIR resources
    Given the patient has clinical data for EHI export
    When a single-patient EHI export is requested
    Then each FHIR resource file should be valid NDJSON
    And each NDJSON line should be valid JSON

  Scenario: EHI export produces CSV for audit logs
    Given the patient has clinical data for EHI export
    And audit events exist for the patient
    When a single-patient EHI export is requested
    Then the audit log file should be valid CSV
    And the CSV should include column headers

  # =============================================================================
  # FILTERING AND SCOPE
  # =============================================================================

  Scenario: EHI export respects date range filter
    Given the patient has clinical data for EHI export
    When a single-patient EHI export is requested with a date range
    Then the export should only include data within the date range

  # =============================================================================
  # PERFORMANCE
  # =============================================================================

  Scenario: EHI export completes within acceptable time
    Given the patient has clinical data for EHI export
    When a single-patient EHI export is requested with timing
    Then the export should complete in under 10 seconds
