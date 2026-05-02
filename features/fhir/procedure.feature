# frozen_string_literal: true

Feature: Procedure FHIR resource
  As a healthcare system
  I need to represent clinical procedures
  So that procedure data is interoperable

  Scenario: Create a valid procedure
    Given a procedure with display "Appendectomy" for patient "100"
    Then the procedure should be valid

  Scenario: Procedure requires patient
    Given a procedure without a patient
    Then the procedure should be invalid

  Scenario: Procedure requires display
    Given a procedure without a display for patient "100"
    Then the procedure should be invalid

  Scenario: Procedure with CPT code
    Given a procedure with display "Appendectomy" and code "44950" system "cpt" for patient "100"
    Then the procedure should be valid

  Scenario: Completed procedure
    Given a completed procedure with display "Appendectomy" for patient "100"
    Then the procedure should be completed

  Scenario: FHIR Procedure includes resourceType
    Given a procedure with display "Appendectomy" for patient "100"
    When I serialize the procedure to FHIR
    Then the FHIR resourceType should be "Procedure"

  Scenario: FHIR Procedure includes subject
    Given a procedure with display "Appendectomy" for patient "100"
    When I serialize the procedure to FHIR
    Then the FHIR subject reference should include "100"

  Scenario: FHIR Procedure includes code
    Given a procedure with display "Appendectomy" and code "44950" system "cpt" for patient "100"
    When I serialize the procedure to FHIR
    Then the FHIR procedure code should include "44950"

  Scenario: FHIR Procedure includes performer
    Given a procedure with display "Appendectomy" and performer "301" for patient "100"
    When I serialize the procedure to FHIR
    Then the FHIR procedure performer should include "301"
