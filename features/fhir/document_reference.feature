Feature: DocumentReference FHIR resource
  As a healthcare system
  I need to manage clinical documents as FHIR resources
  So that documents are discoverable and shareable

  # =============================================================================
  # CREATION & VALIDATION
  # =============================================================================

  Scenario: Create a valid document reference
    Given a document reference with type "clinical-note" for patient "1"
    Then the document reference should be valid

  Scenario: Document reference requires patient
    Given a document reference without a patient
    Then the document reference should be invalid

  Scenario: Document reference requires type
    Given a document reference without a type for patient "1"
    Then the document reference should be invalid

  # =============================================================================
  # DOCUMENT STATUS
  # =============================================================================

  Scenario: Current document status
    Given a document reference with status "current" for patient "1"
    Then the document status should be "current"

  Scenario: Superseded document status
    Given a document reference with status "superseded" for patient "1"
    Then the document status should be "superseded"

  Scenario: Entered in error document status
    Given a document reference with status "entered-in-error" for patient "1"
    Then the document status should be "entered-in-error"

  # =============================================================================
  # DOCUMENT TYPES
  # =============================================================================

  Scenario: Clinical note document
    Given a document reference with type "clinical-note" and display "Progress Note" for patient "1"
    Then the document type display should be "Progress Note"

  Scenario: Discharge summary document
    Given a document reference with type "discharge-summary" and display "Discharge Summary" for patient "1"
    Then the document type display should be "Discharge Summary"

  # =============================================================================
  # DOCUMENT CONTENT
  # =============================================================================

  Scenario: Document with author
    Given a document reference with author "101" for patient "1"
    Then the document author should be "101"

  Scenario: Document with date
    Given a document reference dated "2026-01-15" for patient "1"
    Then the document date should be "2026-01-15"

  # =============================================================================
  # FHIR SERIALIZATION
  # =============================================================================

  Scenario: FHIR DocumentReference includes resourceType
    Given a document reference with type "clinical-note" for patient "1"
    When I serialize the document reference to FHIR
    Then the FHIR resourceType should be "DocumentReference"

  Scenario: FHIR DocumentReference includes subject reference
    Given a document reference with type "clinical-note" for patient "123"
    When I serialize the document reference to FHIR
    Then the FHIR subject reference should be "Patient/123"

  Scenario: FHIR DocumentReference includes type coding
    Given a document reference with type "clinical-note" and display "Progress Note" for patient "1"
    When I serialize the document reference to FHIR
    Then the FHIR type should have display "Progress Note"

  Scenario: FHIR DocumentReference includes status
    Given a document reference with status "current" for patient "1"
    When I serialize the document reference to FHIR
    Then the FHIR document status should be "current"

  Scenario: FHIR DocumentReference includes category
    Given a document reference with category "clinical-note" for patient "1"
    When I serialize the document reference to FHIR
    Then the FHIR category should be present
