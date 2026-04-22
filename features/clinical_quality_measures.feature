Feature: Clinical Quality Measures (ONC § 170.315(c)(1-3))
  As a quality improvement coordinator
  I need to calculate clinical quality measures for patients and populations
  So that I can report on care performance and comply with ONC certification

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
      | 2   | Bob        | Brown     | 1975-08-20 | M   |

  Scenario: Evaluate diabetes A1C measure for patient with controlled A1C
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    When I evaluate measure "diabetes_a1c_control" for patient "1" for period "2025-04-01" to "2026-03-31"
    Then the measure report should show initial population count of 1
    And the measure report should show denominator count of 1
    And the measure report should show numerator count of 1

  Scenario: Evaluate diabetes A1C measure for patient with uncontrolled A1C
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 10.2 recorded on "2026-01-15"
    When I evaluate measure "diabetes_a1c_control" for patient "1" for period "2025-04-01" to "2026-03-31"
    Then the measure report should show initial population count of 1
    And the measure report should show denominator count of 1
    And the measure report should show numerator count of 0

  Scenario: Patient without diabetes is not in initial population
    Given patient "2" has no conditions in valueset "gpra-bgpmu-diabetes-dx"
    When I evaluate measure "diabetes_a1c_control" for patient "2" for period "2025-04-01" to "2026-03-31"
    Then the measure report should show initial population count of 0
    And the measure report should show denominator count of 0
    And the measure report should show numerator count of 0

  Scenario: Evaluate BMI screening measure for patient with BMI recorded
    Given patient "1" has an observation with code "39156-5" and value 24.5 recorded on "2026-02-01"
    When I evaluate measure "bmi_screening" for patient "1" for period "2025-04-01" to "2026-03-31"
    Then the measure report should show initial population count of 1
    And the measure report should show numerator count of 1

  Scenario: Evaluate depression screening for patient with screening completed
    Given patient "1" has an observation with code "44261-6" in valueset "gpra-bgpmu-depression-screening" recorded on "2026-01-10"
    When I evaluate measure "depression_screening" for patient "1" for period "2025-04-01" to "2026-03-31"
    Then the measure report should show initial population count of 1
    And the measure report should show numerator count of 1

  Scenario: Query available measures via FHIR API
    Given the system is configured for FHIR API access
    And I have a valid SMART token with scope "system/*.read"
    When I request "GET /fhir/Measure" with FHIR headers
    Then the response should be a FHIR Bundle
    And the bundle should contain measures

  Scenario: View individual MeasureReport with population counts
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    And the system is configured for FHIR API access
    And I have a valid SMART token with scope "system/*.read"
    When I request "GET /fhir/MeasureReport?measure=diabetes_a1c_control&patient=1&period=2025-04-01,2026-03-31" with FHIR headers
    Then the response should be a FHIR Bundle
    And the bundle should contain a MeasureReport with population groups

  Scenario: Population-level measure evaluation
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    When I evaluate measure "diabetes_a1c_control" for patients "1,2" for period "2025-04-01" to "2026-03-31"
    Then the summary report should show initial population count of 2
    And the summary report should show numerator count of 2
    And the summary report should have a performance rate of 1.0
