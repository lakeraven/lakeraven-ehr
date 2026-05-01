@onc @reconciliation
Feature: Clinical Information Reconciliation
  As a clinician
  I want to reconcile medications, allergies, and problems from external sources
  So that I can maintain an accurate patient record

  ONC § 170.315(b)(2) - Clinical Information Reconciliation

  Background:
    Given a patient exists with DFN "12345"

  # =============================================================================
  # FHIR BUNDLE IMPORT
  # =============================================================================

  Scenario: Import clinical data from FHIR Bundle
    Given a FHIR Bundle containing allergies, conditions, and medications
    When a clinician imports the FHIR Bundle for reconciliation
    Then a reconciliation session should be created
    And the session should contain items for all three resource types
    And the session status should be "in_progress"

  # =============================================================================
  # C-CDA IMPORT
  # =============================================================================

  Scenario: Import clinical data from C-CDA document
    Given a C-CDA document containing clinical data
    When a clinician imports the C-CDA document for reconciliation
    Then a reconciliation session should be created
    And the session source type should be "ccda"

  # =============================================================================
  # MATCHING
  # =============================================================================

  Scenario: Imported items are matched against existing data
    Given the patient has existing allergies in the system
    And a FHIR Bundle containing a duplicate allergy and a new allergy
    When a clinician imports the FHIR Bundle for reconciliation
    Then some items should have match status "duplicate"
    And some items should have match status "new"

  # =============================================================================
  # ACCEPT / REJECT
  # =============================================================================

  Scenario: Clinician accepts a reconciliation item
    Given a reconciliation session exists with pending items
    When the clinician accepts an item
    Then the item decision should be "accepted"
    And the item should record who decided

  Scenario: Clinician rejects a reconciliation item
    Given a reconciliation session exists with pending items
    When the clinician rejects an item
    Then the item decision should be "rejected"

  # =============================================================================
  # BULK OPERATIONS
  # =============================================================================

  Scenario: Clinician accepts all items of a type
    Given a reconciliation session exists with multiple pending allergy items
    When the clinician accepts all allergy items
    Then all allergy items should be accepted

  # =============================================================================
  # COMPLETE SESSION
  # =============================================================================

  Scenario: Complete reconciliation after all decisions made
    Given a reconciliation session exists with all items decided
    When the clinician completes the reconciliation
    Then the session status should be "completed"
    And a provenance record should be created

  Scenario: Cannot complete reconciliation with undecided items
    Given a reconciliation session exists with pending items
    When the clinician attempts to complete the reconciliation
    Then the session should not be completed
