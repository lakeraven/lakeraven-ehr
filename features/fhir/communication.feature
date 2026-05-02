# frozen_string_literal: true

Feature: Communication FHIR resource
  As a healthcare system
  I need to represent secure messages between care team members
  So that clinical messaging is interoperable

  Scenario: Create a valid communication
    Given a communication with content "Lab results ready" from "Practitioner" "201" for patient "100"
    Then the communication should be valid

  Scenario: Communication requires patient
    Given a communication without a patient
    Then the communication should be invalid

  Scenario: Communication requires sender
    Given a communication without a sender for patient "100"
    Then the communication should be invalid

  Scenario: Communication requires content
    Given a communication without content from "Practitioner" "201" for patient "100"
    Then the communication should be invalid

  Scenario: Communication status helpers
    Given a communication with status "completed" from "Practitioner" "201" for patient "100"
    Then the communication should be completed

  Scenario: Communication priority helpers
    Given a communication with priority "urgent" from "Practitioner" "201" for patient "100"
    Then the communication should be urgent

  Scenario: Communication category helpers
    Given a communication with category "alert" from "Practitioner" "201" for patient "100"
    Then the communication should be an alert

  Scenario: Root message detection
    Given a communication with content "Initial message" from "Practitioner" "201" for patient "100"
    Then the communication should be a root message

  Scenario: Reply detection
    Given a communication replying to message "msg-001" from "Practitioner" "201" for patient "100"
    Then the communication should be a reply

  Scenario: FHIR Communication includes resourceType
    Given a communication with content "Lab results ready" from "Practitioner" "201" for patient "100"
    When I serialize the communication to FHIR
    Then the FHIR resourceType should be "Communication"

  Scenario: FHIR Communication includes subject
    Given a communication with content "Lab results ready" from "Practitioner" "201" for patient "100"
    When I serialize the communication to FHIR
    Then the FHIR subject reference should include "100"

  Scenario: FHIR Communication includes payload
    Given a communication with content "Lab results ready" from "Practitioner" "201" for patient "100"
    When I serialize the communication to FHIR
    Then the FHIR communication payload should include "Lab results ready"
