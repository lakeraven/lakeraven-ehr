@cds
Feature: Clinical Decision Support Alerts
  As a healthcare provider
  I need to see clinical alerts on a patient's profile
  So that I can make informed clinical decisions

  Background:
    Given I am logged in as a provider

  Scenario: Display clinical reminders filtered to DUE status
    Given a patient with due clinical reminders
    When I check the patient's background alerts
    Then I should see only DUE reminders
    And each reminder should have a severity level

  Scenario: Display active allergy alerts with severity
    Given a patient with known allergies
    When I check the patient's background alerts
    Then I should see allergy alerts with severity badges
    And allergy severity should be mapped from the severity field

  Scenario: Background alerts do not call DrugInteractionService
    Given a patient with known allergies
    When I check the patient's background alerts
    Then the drug interactions list should be empty

  Scenario: Severity summary aggregates all alert severities
    Given a patient with due clinical reminders
    And a patient with known allergies
    When I check the patient's background alerts
    Then I should see a severity summary with high, moderate, and low counts
