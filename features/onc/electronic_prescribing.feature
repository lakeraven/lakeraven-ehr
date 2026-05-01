@onc
Feature: Electronic Prescribing — NCPDP SCRIPT
  As a prescribing provider
  I want to transmit prescriptions via NCPDP SCRIPT standard
  So that pharmacies receive structured e-prescriptions through Surescripts

  ONC § 170.315(b)(3) — Electronic Prescribing

  Background:
    Given a patient exists with DFN "12345"

  # =============================================================================
  # NCPDP SCRIPT MESSAGE GENERATION
  # =============================================================================

  Scenario: Generate a NewRx NCPDP SCRIPT message
    Given a signed medication order for "Lisinopril 10 MG Oral Tablet"
    When an NCPDP SCRIPT NewRx message is generated
    Then the message should be valid XML
    And the message should have message type "NewRx"
    And the message should include prescriber information
    And the message should include patient information
    And the message should include medication details

  Scenario: Generate a CancelRx NCPDP SCRIPT message
    Given a transmitted prescription with ID "erx-cancel-001"
    When an NCPDP SCRIPT CancelRx message is generated with reason "Patient allergy"
    Then the message should be valid XML
    And the message should have message type "CancelRx"
    And the message should include the cancellation reason

  Scenario: Generate a RefillRequest NCPDP SCRIPT message
    Given a transmitted prescription with ID "erx-refill-001"
    When an NCPDP SCRIPT RxFill message is generated
    Then the message should be valid XML
    And the message should have message type "RxFill"

  Scenario: Generate an RxChangeRequest NCPDP SCRIPT message
    Given a transmitted prescription with ID "erx-change-001"
    And a requested medication change to "Lisinopril 20 MG Oral Tablet"
    When an NCPDP SCRIPT RxChangeRequest message is generated
    Then the message should be valid XML
    And the message should have message type "RxChangeRequest"
    And the message should include the new medication details

  # =============================================================================
  # REFILL AND CHANGE REQUEST WORKFLOWS
  # =============================================================================

  Scenario: Process a pharmacy refill request
    Given a signed medication order for "Metformin 500 MG Oral Tablet"
    And the prescription has been transmitted
    When the pharmacy requests a refill
    Then the refill request should be recorded
    And the refill request status should be "pending"

  Scenario: Approve a refill request
    Given a signed medication order for "Metformin 500 MG Oral Tablet"
    And the prescription has been transmitted
    And the pharmacy has requested a refill
    When the provider approves the refill request
    Then the refill request status should be "approved"
    And an audit event should be recorded for the refill approval

  Scenario: Process a pharmacy change request
    Given a signed medication order for "Lisinopril 10 MG Oral Tablet"
    And the prescription has been transmitted
    When the pharmacy requests a medication change to "Lisinopril 20 MG Oral Tablet"
    Then the change request should be recorded
    And the change request status should be "pending"

  # =============================================================================
  # CONTROLLED SUBSTANCE — EPCS
  # =============================================================================

  Scenario: Flag controlled substance prescription for EPCS
    Given a signed medication order for "Hydrocodone 5 MG Oral Tablet"
    And the medication is DEA Schedule "II"
    When the prescription is validated for transmission
    Then the prescription should require EPCS two-factor authentication
    And the prescription should include DEA schedule information

  # =============================================================================
  # SURESCRIPTS ROUTING
  # =============================================================================

  Scenario: Route prescription through e-prescribing adapter
    Given a signed medication order for "Amoxicillin 500 MG Oral Capsule"
    When the prescription is transmitted via the e-prescribing adapter
    Then the transmission should succeed
    And the transmission result should include a transmission ID

  # =============================================================================
  # PERFORMANCE
  # =============================================================================

  Scenario: NCPDP SCRIPT message generation completes quickly
    Given a signed medication order for "Lisinopril 10 MG Oral Tablet"
    When an NCPDP SCRIPT NewRx message is generated with timing
    Then the generation should complete in under 2 seconds
