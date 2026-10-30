# frozen_string_literal: true

@enrollment @fhir
Feature: Enrollment FHIR integration
  As the PRC system
  I want to check eligibility with the enrollment service
  So that alternate resources are accurately verified

  Background:
    Given the enrollment FHIR service host is "enrollment.example.test"
    And a synthetic patient with DFN "900001" named "TEST,PATIENT ONE"

  Scenario: Check Medicare eligibility through the enrollment FHIR client
    Given the enrollment service accepts Medicare eligibility checks for patient "900001"
    When I check Medicare Part B eligibility for patient "900001" on "2026-03-15"
    Then the eligibility outcome should be enrolled
    And the enrollment service should have received one CoverageEligibilityRequest

  Scenario: Enrollment service unavailable marks check as pending and schedules retry
    Given the enrollment service is unavailable for eligibility checks
    When I check Medicare Part B eligibility for patient "900001" on "2026-03-15"
    Then the eligibility outcome should be pending
    And an enrollment eligibility retry job should be enqueued for that request
    And the enrollment service should have been asked three times

  Scenario: Cached eligibility avoids a repeat API call within one hour
    Given the enrollment service accepts Medicare eligibility checks for patient "900001"
    And I checked Medicare Part B eligibility for patient "900001" one hour ago
    When I check Medicare Part B eligibility for patient "900001" again on "2026-03-15"
    Then the eligibility outcome should be enrolled
    And the enrollment service should have received one CoverageEligibilityRequest

  Scenario: Eligibility response for another patient is an error not enrolled
    Given the enrollment service returns in-force Medicare for patient "900002"
    When I check Medicare Part B eligibility for patient "900001" on "2026-03-15"
    Then the eligibility outcome should be error

  Scenario: Cancelled eligibility response is an error
    Given the enrollment service returns a cancelled Medicare eligibility response for patient "900001"
    When I check Medicare Part B eligibility for patient "900001" on "2026-03-15"
    Then the eligibility outcome should be error

  Scenario: Active Medicaid coverage is returned as a FHIR Coverage resource with plan details
    Given the enrollment service lists active Medicaid coverage for patient "900001"
    When I fetch Medicaid coverage from enrollment for patient "900001"
    Then I should receive a FHIR Coverage with plan name "TEST Medicaid Plan"
    And the Coverage payor should be "TEST State Medicaid Payor"
