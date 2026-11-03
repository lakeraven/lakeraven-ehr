@url_patient_context
Feature: URL-derived patient context with self-clearing on invalid identifiers
  As a clinician
  I need patient context to survive refresh and reject invalid identifiers
  So that a stale session or malformed link can never show the wrong chart

  Background:
    Given demo clinical seeds are loaded
    And the clinician is signed in for URL patient context

  Scenario: Context is re-derived from the URL after refresh
    Given the clinician has the HTML chart for patient 1 open
    When the browser reloads the chart page
    Then patient 1 is the active patient context
    And the banner reflects patient 1

  Scenario: Invalid patient identifier clears context
    Given the clinician has patient 1 open in session
    When the clinician follows a chart link for an invalid patient identifier
    Then the clinician is redirected to patient search with an explanatory message
    And the patient context is cleared
    And no partial patient data is rendered

  Scenario: Backend failure clears rather than freezes context
    Given the clinician has patient 1 open in session
    And the chart patient lookup fails in the backend
    When the clinician opens the HTML chart for patient 1
    Then the patient context is cleared
    And the failure is shown as an error state, not an empty chart
