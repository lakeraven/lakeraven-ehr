@screenings
Feature: Scored PHQ-9 and GAD-7 instruments
  As a therapist
  I need standardized scored screenings on the chart
  So that severity and response to treatment are trackable visit over visit

  Background:
    Given a patient with DFN 123
    And the patient has an active encounter with visit IEN 2090061

  Scenario: Administering a PHQ-9 in clinic
    When the clinician records the following PHQ-9 answers:
      | item | response                  |
      | 1    | Nearly every day          |
      | 2    | More than half the days   |
      | 3    | More than half the days   |
      | 4    | More than half the days   |
      | 5    | Several days              |
      | 6    | Several days              |
      | 7    | Several days              |
      | 8    | Not at all                |
      | 9    | Not at all                |
    Then the screening should be recorded
    And the total score should be 12
    And the severity band should be "moderate"
    And the score should be retrievable as an Observation with LOINC code "44261-6"
    And the answers should be retrievable as a QuestionnaireResponse with 9 items

  Scenario: Administering a GAD-7 in clinic
    When the clinician records every GAD-7 item as "More than half the days"
    Then the screening should be recorded
    And the total score should be 14
    And the severity band should be "moderate"
    And the score should be retrievable as an Observation with LOINC code "70274-6"

  Scenario Outline: PHQ-9 severity bands
    When the clinician records a PHQ-9 totalling <total>
    Then the severity band should be "<band>"

    Examples:
      | total | band              |
      | 0     | minimal           |
      | 4     | minimal           |
      | 5     | mild              |
      | 9     | mild              |
      | 10    | moderate          |
      | 14    | moderate          |
      | 15    | moderately severe |
      | 19    | moderately severe |
      | 20    | severe            |
      | 27    | severe            |

  Scenario Outline: GAD-7 severity bands
    When the clinician records a GAD-7 totalling <total>
    Then the severity band should be "<band>"

    Examples:
      | total | band     |
      | 0     | minimal  |
      | 4     | minimal  |
      | 5     | mild     |
      | 9     | mild     |
      | 10    | moderate |
      | 14    | moderate |
      | 15    | severe   |
      | 21    | severe   |

  Scenario: PHQ-9 item 9 positive triggers a safety prompt
    When the clinician answers PHQ-9 item 9 "Several days" and every other item "Not at all"
    Then the screening should not be recorded
    And a safety prompt should be required before the screening can be submitted

  Scenario: The safety prompt is displayed on the form before it can be submitted
    Given the clinician is signed in
    When the clinician submits a PHQ-9 with item 9 answered "Nearly every day"
    Then the form is redisplayed with a safety prompt
    And no score is recorded

  Scenario: Acknowledging the safety prompt records the screening
    When the clinician answers PHQ-9 item 9 "Several days" and every other item "Not at all"
    And the clinician acknowledges the safety prompt and resubmits
    Then the screening should be recorded
    And the screening should be flagged for safety follow-up

  Scenario: Item 9 answered "not at all" needs no safety prompt
    When the clinician records every PHQ-9 item as "Not at all"
    Then the screening should be recorded
    And no safety prompt should be required

  Scenario: Incomplete instrument is not scored
    When the clinician submits a PHQ-9 with items 3 and 8 unanswered
    Then the screening should not be recorded
    And the missing items should be reported as 3 and 8
    And no score should be recorded

  Scenario: A screening trends on the chart over time
    When the clinician records a PHQ-9 totalling 18 on "2026-03-01"
    And the clinician records a PHQ-9 totalling 9 on "2026-05-01"
    Then the patient should have 2 trended PHQ-9 scores
    And the scores in date order should be 18 and 9

  # Pre-visit administration via a tokenized public link is #471. The delivery
  # mechanism is not built here; what IS built and asserted is that scoring and
  # persistence never require a clinician session, so that link can call the
  # same path.
  Scenario: A screening can be scored without a clinician session
    When a GAD-7 is completed by the patient before arrival
    Then the screening should be recorded
    And the screening should be attributed to the patient rather than a clinician
