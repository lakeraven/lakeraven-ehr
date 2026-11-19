@app @note_signing_audit
Feature: Signing a progress note is audited
  As a compliance officer
  I need every attempt to sign a progress note to leave an append-only audit record
  So that who signed which note, for which patient, and what text they signed can be shown later

  Background:
    Given a patient with DFN 8791
    And a demo visit with IEN 2090061
    And I am the authoring provider with DUZ 2843

  Scenario: Signing a note writes one audit event
    Given a created progress note
    When the provider signs the note with signature code "SIGSECRET42"
    Then the note signing should succeed
    And exactly one note signing audit event should be recorded
    And the audit event type should be "application"
    And the audit event action should be "E"
    And the audit event agent should be "2843"
    And the audit event should be successful
    And the note signing audit event should identify the signed note
    And the note signing audit event should name patient 8791
    And the note signing audit event should not contain "SIGSECRET42"

  Scenario: A wrong signature code is audited as a refusal
    Given a created progress note
    And the signature code will fail validation
    When the provider signs the note with signature code "SIGSECRET42"
    Then the note signing should fail with :invalid_signature_code
    And no sign action should reach the e-signature gateway
    And exactly one note signing audit event should be recorded
    And the audit event action should be "E"
    And the audit event agent should be "2843"
    And the audit event should be a minor failure
    And the note signing audit event should identify the signed note
    And the note signing audit event should name patient 8791
    And the note signing audit event should give the reason "invalid_signature_code"
    And the note signing audit event should not contain "SIGSECRET42"

  Scenario: Signing with no note is audited as a refusal
    When the provider signs the note with signature code "SIGSECRET42"
    Then the note signing should fail with :no_note
    And exactly one note signing audit event should be recorded
    And the audit event agent should be "2843"
    And the audit event should be a minor failure
    And the note signing audit event should identify no note
    And the note signing audit event should give the reason "no_note"
    And the note signing audit event should not contain "SIGSECRET42"

  Scenario: The signing audit event cannot be updated or deleted
    Given a created progress note
    When the provider signs the note with signature code "SIGSECRET42"
    Then exactly one note signing audit event should be recorded
    And the note signing audit event cannot be updated
    And the note signing audit event cannot be deleted

  Scenario: The audit event holds a hash of the signed note body and of the note as filed
    Given a created progress note
    When the provider signs the note with signature code "SIGSECRET42"
    Then exactly one note signing audit event should be recorded
    And the note signing audit event should hold the SHA-256 and row count of the signed note body
    And the note signing audit event should hold the SHA-256 and row count of the note as filed
    And the note as filed should include the signature block
    And the note signing audit event should not contain the note text
    And the record hash should match the current note body
    When the note text is later changed to "Demo note text, altered after signing."
    Then the record hash should no longer match the current note body

  Scenario: An unchanged signed note still matches when it is read again
    Given a created progress note
    When the provider signs the note with signature code "SIGSECRET42"
    Then exactly one note signing audit event should be recorded
    And the record hash should match the current note body
    And the record hash should match the current note body

  Scenario: Rows appended after signing are detected
    Given a created progress note
    When the provider signs the note with signature code "SIGSECRET42"
    Then exactly one note signing audit event should be recorded
    And the record hash should match the current note body
    When a row "Addendum: synthetic row appended after signing." is appended to the signed note
    Then the signed rows alone should still reproduce the content hash
    But the record hash should no longer match the current note body

  Scenario: A note changed between the signer's read and filing is recorded as a mismatch
    Given a created progress note
    And the note text will be changed to "Demo note text, altered before filing." between the signer's read and filing
    When the provider signs the note with signature code "SIGSECRET42"
    Then the note signing should succeed
    And exactly one note signing audit event should be recorded
    And the audit event should be successful
    And the note signing audit event should identify the signed note
    And the note signing audit event should record that the filed note does not match what was signed
    And the note signing audit event should not contain "SIGSECRET42"

  Scenario: The hash still matches after TIU changes the header and appends the signature
    When the provider creates a progress note with title 8927 and text:
      """
      S: Synthetic cough for two days.
      P: Synthetic plan: fluids and rest.
      """
    And the provider signs the note with signature code "SIGSECRET42"
    Then the note signing should succeed
    And exactly one note signing audit event should be recorded
    And the note signing audit event should hold the SHA-256 and row count of the signed note body
    And the note signing audit event should hold the SHA-256 and row count of the note as filed
    When TIU later returns the signed note with a "COMPLETED" header and a signature block
    Then the re-read note should differ from the body alone
    And the record hash should match the re-read note body
    When the note text is later changed to:
      """
      S: Synthetic cough for two days.
      P: Synthetic plan, altered after signing.
      """
    And TIU later returns the signed note with a "COMPLETED" header and a signature block
    Then the record hash should no longer match the re-read note body
