# frozen_string_literal: true

Feature: SMART launch context
  As a SMART-on-FHIR application
  I need launch context tokens to bind patient and encounter
  So that the OAuth flow can resolve clinical context

  Scenario: Mint a launch context with patient
    Given an OAuth application "app-001"
    When I mint a launch context for patient "100"
    Then the launch context should have a token
    And the launch context token should start with "lc_"
    And the launch context should expire in the future

  Scenario: Mint a launch context with patient and encounter
    Given an OAuth application "app-001"
    When I mint a launch context for patient "100" and encounter "enc-200"
    Then the SMART context should include patient "100"
    And the SMART context should include encounter "enc-200"

  Scenario: Mint a launch context with facility
    Given an OAuth application "app-001"
    When I mint a launch context for patient "100" with facility "463"
    Then the launch context facility should be "463"

  Scenario: SMART context includes patient only when present
    Given an OAuth application "app-001"
    When I mint a launch context without a patient
    Then the SMART context should not include patient

  Scenario: SMART context includes encounter only when present
    Given an OAuth application "app-001"
    When I mint a launch context for patient "100"
    Then the SMART context should not include encounter

  Scenario: Launch context token is unique
    Given an OAuth application "app-001"
    When I mint two launch contexts for patient "100"
    Then the tokens should be different
