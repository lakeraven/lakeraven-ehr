# frozen_string_literal: true

Feature: ServiceRequest FHIR resource
  As a healthcare system
  I need to represent healthcare referrals
  So that referral data is interoperable

  Scenario: Create a valid service request
    Given a service request for "Cardiology Consult" from provider "201" for patient "100"
    Then the service request should be valid

  Scenario: Service request requires patient
    Given a service request without a patient
    Then the service request should be invalid

  Scenario: Service request requires service
    Given a service request without a service from provider "201" for patient "100"
    Then the service request should be invalid

  Scenario: Active service request
    Given a service request for "Cardiology Consult" with status "active" from provider "201" for patient "100"
    Then the service request should be active

  Scenario: Completed service request
    Given a service request for "Cardiology Consult" with status "completed" from provider "201" for patient "100"
    Then the service request should be completed

  Scenario: Urgent service request
    Given a service request for "Cardiology Consult" with urgency "URGENT" from provider "201" for patient "100"
    Then the service request should be urgent

  Scenario: Overdue service request
    Given a service request for "Cardiology Consult" with appointment "2025-01-01" from provider "201" for patient "100"
    Then the service request should be overdue

  Scenario: Priority levels
    Given a service request for "Cardiology Consult" with urgency "EMERGENT" from provider "201" for patient "100"
    Then the service request priority should be 1

  Scenario: FHIR ServiceRequest includes resourceType
    Given a service request for "Cardiology Consult" from provider "201" for patient "100"
    When I serialize the service request to FHIR
    Then the FHIR resourceType should be "ServiceRequest"

  Scenario: FHIR ServiceRequest includes subject
    Given a service request for "Cardiology Consult" from provider "201" for patient "100"
    When I serialize the service request to FHIR
    Then the FHIR subject reference should include "100"
