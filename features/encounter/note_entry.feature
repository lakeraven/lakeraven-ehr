Feature: Write and sign a progress note on an open encounter
  As a clinical provider
  I need to write a progress note against the visit and sign it
  So that the clinical record of the visit is complete and attributable

  Background:
    Given a patient with DFN 8791
    And a demo visit with IEN 2090061
    And I am the authoring provider with DUZ 2843

  Scenario: Provider creates a progress note and writes its text
    When the provider creates a progress note with title 8927 and text:
      """
      S: Sore throat and congestion x3 days.
      O: T 99.1F, HEENT: pharyngeal erythema, no exudate.
      A: Acute upper respiratory infection (J06.9).
      P: Supportive care; return if worsening.
      """
    Then the note create should succeed with a note IEN
    And the note gateway should receive the note text

  Scenario: Provider cannot create a note without a title
    When the provider creates a progress note with no title
    Then the note create should fail with :missing_title

  Scenario: Provider signs the note with a valid signature code
    Given a created progress note
    When the provider signs the note with signature code "DEMOPASS"
    Then the note signing should succeed
    And the e-signature gateway should receive a sign action for the note

  Scenario: Signing is rejected with an invalid signature code
    Given a created progress note
    And the signature code will fail validation
    When the provider signs the note with signature code "WRONG"
    Then the note signing should fail with :invalid_signature_code
    And no sign action should reach the e-signature gateway

  Scenario: Provider cannot sign a note that was never created
    When the provider signs the note with signature code "DEMOPASS"
    Then the note signing should fail with :no_note
