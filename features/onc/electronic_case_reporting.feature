@onc
Feature: Electronic Case Reporting (eCR)
  As a public health authority
  I want reportable conditions to automatically generate case reports
  So that communicable diseases are reported to ECLRS per state requirements

  ONC § 170.315(f)(5) — Electronic Case Reporting

  Background:
    Given a patient exists with DFN "12345"

  # =============================================================================
  # REPORTABLE CONDITION TRIGGERS
  # =============================================================================

  Scenario: Detect a reportable condition from diagnosis
    Given the patient has a confirmed diagnosis of "A15.0" for "Tuberculosis of lung"
    When the condition is evaluated for reportability
    Then the condition should be flagged as reportable
    And the trigger should reference the reportable conditions list

  Scenario: Non-reportable condition is not flagged
    Given the patient has a confirmed diagnosis of "E11.9" for "Type 2 diabetes mellitus"
    When the condition is evaluated for reportability
    Then the condition should not be flagged as reportable

  Scenario: Reportable condition list includes NYS notifiable diseases
    When the reportable conditions list is loaded
    Then the list should include tuberculosis
    And the list should include hepatitis B
    And the list should include gonorrhea
    And the list should include chlamydia
    And the list should include HIV

  # =============================================================================
  # eICR DOCUMENT GENERATION
  # =============================================================================

  Scenario: Generate an eICR for a reportable condition
    Given the patient has a confirmed diagnosis of "A15.0" for "Tuberculosis of lung"
    And the patient has clinical data for the case report
    When an eICR document is generated
    Then the eICR should be valid XML
    And the eICR should have the eICR template ID
    And the eICR should include patient demographics
    And the eICR should include the reportable condition
    And the eICR should include the responsible provider

  Scenario: eICR includes encounter information
    Given the patient has a confirmed diagnosis of "A15.0" for "Tuberculosis of lung"
    And the patient has clinical data for the case report
    When an eICR document is generated
    Then the eICR should include the triggering encounter

  # =============================================================================
  # REPORTABILITY RESPONSE (RR) PROCESSING
  # =============================================================================

  Scenario: Process a reportability response
    Given an eICR was submitted for the patient
    When a reportability response is received indicating "reportable"
    Then the response status should be recorded
    And the response should reference the original eICR

  Scenario: Process a non-reportable response
    Given an eICR was submitted for the patient
    When a reportability response is received indicating "not reportable"
    Then the response status should be recorded as not reportable

  # =============================================================================
  # ECLRS TRANSMISSION
  # =============================================================================

  Scenario: Transmit eICR to ECLRS
    Given the patient has a confirmed diagnosis of "A15.0" for "Tuberculosis of lung"
    And the patient has clinical data for the case report
    And an eICR document has been generated
    When the eICR is transmitted to ECLRS
    Then the ECR transmission should succeed
    And the ECR transmission should include a tracking ID
    And an audit event should be recorded for the submission

  # =============================================================================
  # PERFORMANCE
  # =============================================================================

  Scenario: eICR generation completes quickly
    Given the patient has a confirmed diagnosis of "A15.0" for "Tuberculosis of lung"
    And the patient has clinical data for the case report
    When an eICR document is generated with timing
    Then the generation should complete in under 2 seconds
