@patient_banner
Feature: Persistent patient banner
  As a clinician on a shared clinic device
  I need the active patient identity visible on every screen
  So that I never document against the wrong chart

  Background:
    Given demo clinical seeds are loaded

  Scenario: Banner is visible on every chart screen
    Given patient "Anderson,Alice" is the active patient context
    When the clinician navigates to the dashboard
    Then the patient banner shows name, MRN, DOB, age, and sex
    And the patient banner remains visible when the page scrolls
    When the clinician navigates to the screenings index for that patient
    Then the patient banner shows name, MRN, DOB, age, and sex
    When the clinician navigates to the HTML chart for that patient
    Then the patient banner shows name, MRN, DOB, age, and sex

  Scenario: Allergies are always shown, even when empty
    Given patient "DEMOPATIENT,MARA" is the active patient context
    And the active patient has no recorded allergies in the chart source
    When the clinician navigates to the dashboard
    Then the banner allergies field displays "None recorded"
    And the banner allergies field has state "none-recorded"
    And the allergies field is not hidden

  Scenario: Clinician explicitly clears patient context
    Given patient "Anderson,Alice" is the active patient context
    When the clinician activates "Clear patient context"
    Then no patient is in context
    And the banner shows the empty state directing to chart search

  Scenario: No patient selected
    Given the clinician is signed in with no patient in context
    When the clinician navigates to the dashboard
    Then the banner shows "No patient selected" with a link to chart search
    And no clinical screen renders patient data

  Scenario: Signed out login page shows no patient data
    Given the clinician is not signed in
    When the clinician visits the login page
    Then no patient data is rendered
