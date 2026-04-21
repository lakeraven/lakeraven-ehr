Feature: Encounter management
  As a clinical provider
  I need to create, view, and close encounters
  So that I can document patient visits per ONC § 170.315(g)(10)

  # ===========================================================================
  # CREATE
  # ===========================================================================

  Scenario: Provider creates a walk-in ambulatory encounter
    Given a new encounter with status "in-progress" class_code "AMB" and patient_dfn 1
    Then the encounter should be valid
    And the encounter should be in_progress
    And the encounter should be ambulatory

  Scenario: Provider creates a virtual encounter
    Given a new encounter with status "in-progress" class_code "VR" and patient_dfn 1
    Then the encounter should be valid
    And the encounter class_display should be "Virtual"

  Scenario: Provider creates an emergency encounter
    Given a new encounter with status "in-progress" class_code "EMER" and patient_dfn 1
    Then the encounter should be valid
    And the encounter should be emergency

  Scenario: Encounter creation fails without required fields
    Given a new encounter with status "" class_code "" and patient_dfn 1
    Then the encounter should not be valid

  # ===========================================================================
  # CLOSE / CANCEL
  # ===========================================================================

  Scenario: Provider closes an encounter with diagnosis
    Given an in-progress ambulatory encounter for patient 1
    When the provider closes the encounter with reason_code "R10.9" reason_display "Abdominal pain"
    Then the encounter should be finished
    And the encounter reason_display should be "Abdominal pain"

  Scenario: Provider cannot close an already finished encounter
    Given a finished ambulatory encounter for patient 1
    When the provider attempts to close the encounter
    Then the close should fail with "already finished"

  Scenario: Provider cancels a planned encounter
    Given a planned ambulatory encounter for patient 1
    When the provider cancels the encounter
    Then the encounter should be cancelled

  # ===========================================================================
  # PARTICIPANTS
  # ===========================================================================

  Scenario: Provider adds a participant to an encounter
    Given an in-progress ambulatory encounter for patient 1
    When the provider adds practitioner "101" as a participant
    Then the encounter should have 1 participant
    And the encounter practitioner_identifier should be "101"

  # ===========================================================================
  # FHIR SERIALIZATION
  # ===========================================================================

  Scenario: Closed encounter serializes with reason and period
    Given an in-progress ambulatory encounter for patient 1
    And the encounter started at "2025-06-01T09:00"
    When the provider closes the encounter with reason_code "R10.9" reason_display "Abdominal pain"
    When I serialize the encounter to FHIR
    Then the FHIR resourceType should be "Encounter"
    And the FHIR status should be "finished"
    And the FHIR reasonCode text should be "Abdominal pain"
