@onc
Feature: Electronic Laboratory Reporting (ELR)
  As a public health authority
  I want reportable lab results to be transmitted electronically
  So that notifiable conditions are reported to ECLRS per state requirements

  ONC § 170.315(f)(3) — Transmission to Public Health Agencies — Reportable Laboratory Tests

  Background:
    Given a patient exists with DFN "12345"

  # =============================================================================
  # REPORTABLE LAB TRIGGER DETECTION
  # =============================================================================

  Scenario: Detect a reportable lab result by LOINC code
    Given the patient has a lab result with LOINC "11585-7" for "Hepatitis B virus surface Ag"
    When the lab result is evaluated for reportability
    Then the lab should be flagged as reportable
    And the trigger should reference the reportable lab tests list

  Scenario: Non-reportable lab result is not flagged
    Given the patient has a lab result with LOINC "2093-3" for "Cholesterol"
    When the lab result is evaluated for reportability
    Then the lab should not be flagged as reportable

  Scenario: Reportable lab list includes NYS notifiable tests
    When the reportable lab tests list is loaded
    Then the list should include hepatitis B surface antigen
    And the list should include HIV viral load
    And the list should include chlamydia NAAT
    And the list should include gonorrhea culture
    And the list should include blood lead level

  # =============================================================================
  # HL7 ORU MESSAGE GENERATION
  # =============================================================================

  Scenario: Generate HL7 v2.5.1 ORU message for reportable lab
    Given the patient has a lab result with LOINC "11585-7" for "Hepatitis B virus surface Ag"
    And the patient has clinical data for the lab report
    When an HL7 ORU message is generated for the lab result
    Then the ORU message should contain the MSH segment
    And the ORU message should contain the PID segment
    And the ORU message should contain the OBR segment
    And the ORU message should contain the OBX segment
    And the OBX segment should include the LOINC code

  Scenario: ORU message includes specimen information
    Given the patient has a lab result with LOINC "11585-7" for "Hepatitis B virus surface Ag"
    And the patient has clinical data for the lab report
    When an HL7 ORU message is generated for the lab result
    Then the ORU message should contain the SPM segment

  # =============================================================================
  # ECLRS TRANSMISSION
  # =============================================================================

  Scenario: Transmit reportable lab to ECLRS
    Given the patient has a lab result with LOINC "11585-7" for "Hepatitis B virus surface Ag"
    And the patient has clinical data for the lab report
    And an HL7 ORU message has been generated
    When the ORU message is transmitted to ECLRS
    Then the ELR transmission should succeed
    And the ELR transmission should include a tracking ID
    And an audit event should be recorded for the lab submission

  # =============================================================================
  # SNOMED ORGANISM CODING
  # =============================================================================

  Scenario: Reportable lab includes SNOMED-coded organism
    Given the patient has a lab result with LOINC "11585-7" for "Hepatitis B virus surface Ag"
    And the lab result has organism "Hepatitis B virus" coded as SNOMED "81665004"
    And the patient has clinical data for the lab report
    When an HL7 ORU message is generated for the lab result
    Then the OBX segment should include the SNOMED organism code

  # =============================================================================
  # PERFORMANCE
  # =============================================================================

  Scenario: ORU message generation completes quickly
    Given the patient has a lab result with LOINC "11585-7" for "Hepatitis B virus surface Ag"
    And the patient has clinical data for the lab report
    When an HL7 ORU message is generated with timing
    Then the generation should complete in under 2 seconds
