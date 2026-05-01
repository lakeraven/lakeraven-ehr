@onc
Feature: Transitions of Care — C-CDA Send
  As a clinical provider
  I want to generate and transmit C-CDA documents
  So that I can share patient clinical summaries during care transitions

  ONC § 170.315(b)(1) — Transitions of Care

  Background:
    Given a patient exists with DFN "12345"

  # =============================================================================
  # C-CDA GENERATION — create valid C-CDA from patient data
  # =============================================================================

  Scenario: Generate a Continuity of Care Document
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated for the patient
    Then the document should be valid XML
    And the document should have CCD template ID "2.16.840.1.113883.10.20.22.1.2"
    And the document should include the patient demographics

  Scenario: Generated C-CDA includes allergies section
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated for the patient
    Then the document should include an allergies section
    And the allergies section should contain coded entries

  Scenario: Generated C-CDA includes problems section
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated for the patient
    Then the document should include a problems section
    And the problems section should contain coded entries

  Scenario: Generated C-CDA includes medications section
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated for the patient
    Then the document should include a medications section
    And the medications section should contain coded entries

  Scenario: Generated C-CDA includes vital signs section
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated for the patient
    Then the document should include a vital signs section

  Scenario: Generated C-CDA includes encounters section
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated for the patient
    Then the document should include an encounters section

  # =============================================================================
  # ROUND-TRIP VALIDATION — generated C-CDA can be re-parsed
  # =============================================================================

  Scenario: Generated C-CDA can be parsed by CcdaParser
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated for the patient
    And the generated document is parsed by CcdaParser
    Then the parsed allergies should match the patient allergies
    And the parsed conditions should match the patient conditions
    And the parsed medications should match the patient medications

  # =============================================================================
  # PERFORMANCE — (b)(1) test procedure requires timing
  # =============================================================================

  Scenario: C-CDA generation completes within acceptable time
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated with timing
    Then the generation should complete in under 5 seconds

  # =============================================================================
  # DOCUMENT METADATA — required for transmission
  # =============================================================================

  Scenario: Generated C-CDA includes author and custodian
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated for the patient
    Then the document should include an author section
    And the document should include a custodian section

  Scenario: Generated C-CDA includes document type code
    Given the patient has clinical data for a care summary
    When a C-CDA document is generated for the patient
    Then the document type code should be "34133-9" for Summarization of Episode Note
