@behavioral_health @pending
Feature: Scored screening instruments with due and overdue state
  As a behavioral-health clinician
  I need PHQ-9 and GAD-7 to be scored, stored discretely, and to tell me when they are due
  So that screening happens on cadence instead of when someone remembers

  # Specification ahead of implementation (#474). Steps are intentionally
  # undefined rather than stubbed — an undefined step reports as undefined; a
  # stubbed one reports as passing and is worse than no test at all (#484).

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
    And the screening interval for "phq9" is 90 days
    And the screening interval for "gad7" is 90 days

  # ---------------------------------------------------------------------------
  # Scoring
  # ---------------------------------------------------------------------------

  Scenario: PHQ-9 total score is computed from item responses
    When I record a "phq9" for patient "1" with item responses:
      | item | value |
      | 1    | 3     |
      | 2    | 3     |
      | 3    | 2     |
      | 4    | 2     |
      | 5    | 1     |
      | 6    | 1     |
      | 7    | 1     |
      | 8    | 0     |
      | 9    | 0     |
    Then the recorded "phq9" score should be 13
    And the recorded "phq9" severity band should be "moderate"

  Scenario: GAD-7 total score is computed from item responses
    When I record a "gad7" for patient "1" with item responses:
      | item | value |
      | 1    | 2     |
      | 2    | 2     |
      | 3    | 2     |
      | 4    | 1     |
      | 5    | 1     |
      | 6    | 1     |
      | 7    | 1     |
    Then the recorded "gad7" score should be 10
    And the recorded "gad7" severity band should be "moderate"

  Scenario: An incomplete instrument is not scored
    When I record a "phq9" for patient "1" with only 6 of 9 items answered
    Then the instrument should be rejected as incomplete
    And no score should be stored

  Scenario: Item responses are stored discretely, not only as a total
    When I record a "phq9" for patient "1" with item responses:
      | item | value |
      | 1    | 1     |
      | 2    | 1     |
      | 3    | 1     |
      | 4    | 1     |
      | 5    | 1     |
      | 6    | 1     |
      | 7    | 1     |
      | 8    | 1     |
      | 9    | 2     |
    Then each of the 9 item responses should be retrievable individually
    And item 9 for patient "1" should have value 2

  # ---------------------------------------------------------------------------
  # Item 9 — self-harm is a clinical signal, not a number in a total
  # ---------------------------------------------------------------------------

  Scenario: A positive PHQ-9 item 9 raises a safety flag regardless of total score
    When I record a "phq9" for patient "1" with a total score of 4 and item 9 answered 1
    Then a self-harm safety flag should be raised for patient "1"
    And the safety flag should be raised even though the total score band is "minimal"

  Scenario: A zero item 9 raises no safety flag
    When I record a "phq9" for patient "1" with a total score of 18 and item 9 answered 0
    Then no self-harm safety flag should be raised for patient "1"

  # ---------------------------------------------------------------------------
  # Due / overdue — the cadence is the point
  # ---------------------------------------------------------------------------

  Scenario: An instrument never administered is due
    Given patient "1" has no recorded "phq9"
    Then the "phq9" for patient "1" should be "due"

  Scenario: An instrument inside its interval is not due
    Given patient "1" has a "phq9" recorded 30 days ago
    Then the "phq9" for patient "1" should be "not_due"

  Scenario: An instrument past its interval is overdue
    Given patient "1" has a "phq9" recorded 91 days ago
    Then the "phq9" for patient "1" should be "overdue"

  Scenario: Due state is surfaced on the chart, not only in a report
    Given patient "1" has a "phq9" recorded 91 days ago
    And patient "1" has a "gad7" recorded 10 days ago
    When I open the chart for patient "1"
    Then the chart should show a due banner for "phq9"
    And the chart should not show a due banner for "gad7"

  Scenario: The due banner links to the instrument for the patient in context
    Given patient "1" has a "phq9" recorded 91 days ago
    When I open the chart for patient "1"
    And I follow the due banner for "phq9"
    Then I should be on the "phq9" entry screen for patient "1"

  Scenario: Recording the instrument clears its due state
    Given patient "1" has a "phq9" recorded 91 days ago
    When I record a complete "phq9" for patient "1"
    Then the "phq9" for patient "1" should be "not_due"
    And the chart should not show a due banner for "phq9"

  # ---------------------------------------------------------------------------
  # Interval is configuration, not a constant
  # ---------------------------------------------------------------------------

  Scenario: A site with a different screening cadence gets its own interval
    Given the screening interval for "phq9" is 180 days
    And patient "1" has a "phq9" recorded 91 days ago
    Then the "phq9" for patient "1" should be "not_due"

  # ---------------------------------------------------------------------------
  # Audit
  # ---------------------------------------------------------------------------

  Scenario: Recording an instrument produces an audit event
    When I record a complete "phq9" for patient "1"
    Then an audit event should exist with action "C" and entity type "Observation"
