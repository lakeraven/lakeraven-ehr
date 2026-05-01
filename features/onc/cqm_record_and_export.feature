@onc
Feature: CQM Record and Export (ONC § 170.315(c)(1))
  As a quality improvement coordinator
  I need to record clinical quality data and export it in standard formats
  So that I can demonstrate ONC compliance and submit quality reports

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
      | 2   | Bob        | Brown     | 1975-08-20 | M   |

  # ---------------------------------------------------------------------------
  # (c)(1) Test Procedure Step 1: Supported measures are documented
  # ---------------------------------------------------------------------------

  Scenario: System documents supported clinical quality measures
    When the supported measures list is loaded
    Then the list should include measure "diabetes_a1c_control" with NQF "0059"
    And the list should include measure "bmi_screening" with NQF "0421"
    And the list should include measure "depression_screening" with NQF "0418"
    And each measure should have population criteria defined

  # ---------------------------------------------------------------------------
  # (c)(1) Test Procedure Step 2: Record clinical quality data
  # ---------------------------------------------------------------------------

  Scenario: Record clinical quality data for a patient
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    When I evaluate measure "diabetes_a1c_control" for patient "1" for period "2025-04-01" to "2026-03-31"
    Then the measure report should show initial population count of 1
    And the measure report should show numerator count of 1

  # ---------------------------------------------------------------------------
  # (c)(1) Test Procedure Step 3: Export QRDA Category I (individual patient)
  # ---------------------------------------------------------------------------

  Scenario: Export QRDA Category I for individual patient
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    When I export a QRDA Category I for patient "1" and measure "diabetes_a1c_control" for period "2025-04-01" to "2026-03-31"
    Then the QRDA I document should be valid XML
    And the QRDA I should contain the QRDA I template ID
    And the QRDA I should contain the patient demographics
    And the QRDA I should contain the measure reference for NQF "0059"
    And the QRDA I should contain population criteria results

  Scenario: QRDA Category I includes observation data entries
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    When I export a QRDA Category I for patient "1" and measure "diabetes_a1c_control" for period "2025-04-01" to "2026-03-31"
    Then the QRDA I should contain a lab result entry with LOINC "4548-4"
    And the QRDA I should contain a condition entry with code "E11.9"

  # ---------------------------------------------------------------------------
  # (c)(1) Test Procedure Step 4: Export QRDA Category III (aggregate)
  # ---------------------------------------------------------------------------

  Scenario: Export QRDA Category III for population
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    And patient "2" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "2" has an observation with code "4548-4" and value 10.2 recorded on "2026-01-15"
    When I export a QRDA Category III for measure "diabetes_a1c_control" for patients "1,2" for period "2025-04-01" to "2026-03-31"
    Then the QRDA III document should be valid XML
    And the QRDA III should contain the QRDA III template ID
    And the QRDA III should contain the measure reference for NQF "0059"
    And the QRDA III should contain aggregate population counts
    And the QRDA III should show a performance rate

  # ---------------------------------------------------------------------------
  # (c)(1) Test Procedure Step 5: Export via FHIR MeasureReport
  # ---------------------------------------------------------------------------

  Scenario: Export CQM data as FHIR MeasureReport
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    And the system is configured for FHIR API access
    And I have a valid SMART token with scope "system/*.read"
    When I request "GET /fhir/MeasureReport?measure=diabetes_a1c_control&patient=1&period=2025-04-01,2026-03-31" with FHIR headers
    Then the response should be a FHIR Bundle
    And the bundle should contain a MeasureReport with population groups

  # ---------------------------------------------------------------------------
  # Performance
  # ---------------------------------------------------------------------------

  Scenario: QRDA export completes within acceptable time
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    When I export a QRDA Category I with timing for patient "1" and measure "diabetes_a1c_control" for period "2025-04-01" to "2026-03-31"
    Then the QRDA export should complete within 2 seconds
