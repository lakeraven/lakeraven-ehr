@onc
Feature: CQM Import and Calculate (ONC 170.315(c)(2))
  As a quality improvement coordinator
  I need to import clinical quality measure definitions and calculate them
  So that I can evaluate care performance using standardized measures

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
      | 2   | Bob        | Brown     | 1975-08-20 | M   |

  # ---------------------------------------------------------------------------
  # (c)(2) Test Procedure Step 1: Import measure from FHIR resource
  # ---------------------------------------------------------------------------

  Scenario: Import a FHIR Measure resource
    When a FHIR Measure resource is imported with:
      | field      | value                                   |
      | id         | test_hypertension                       |
      | title      | Controlling High Blood Pressure         |
      | nqf_number | 0018                                    |
      | scoring    | proportion                              |
    Then the import should succeed
    And measure "test_hypertension" should be available in the system
    And measure "test_hypertension" should have NQF number "0018"

  Scenario: Import multiple measures from a FHIR Bundle
    When a FHIR Bundle is imported containing measures:
      | id               | title                    | nqf_number |
      | test_bundle_m1   | Bundle Measure One       | 0001       |
      | test_bundle_m2   | Bundle Measure Two       | 0002       |
    Then 2 measures should be imported successfully
    And measure "test_bundle_m1" should be available in the system
    And measure "test_bundle_m2" should be available in the system

  Scenario: Import rejects invalid measure data
    When an invalid FHIR Measure resource is imported
    Then the import should fail with validation errors

  # ---------------------------------------------------------------------------
  # (c)(2) Test Procedure Step 2: Resolve data requirements
  # ---------------------------------------------------------------------------

  Scenario: Query data requirements for an imported measure
    When data requirements are requested for measure "diabetes_a1c_control"
    Then the data requirements should list referenced ValueSets
    And each data requirement should include a canonical URL
    And each data requirement should indicate local availability

  # ---------------------------------------------------------------------------
  # (c)(2) Test Procedure Step 3: End-to-end import -> calculate -> report
  # ---------------------------------------------------------------------------

  Scenario: Calculate a configured measure for a patient
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    When measure "diabetes_a1c_control" is calculated for patient "1" for period "2025-04-01" to "2026-03-31"
    Then the calculation should produce a MeasureReport
    And the MeasureReport should show the patient in the initial population
    And the MeasureReport should show the patient in the numerator

  Scenario: Calculate a configured measure for a population
    Given patient "1" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "1" has an observation with code "4548-4" and value 7.5 recorded on "2026-01-15"
    And patient "2" has a condition with code "E11.9" in valueset "gpra-bgpmu-diabetes-dx"
    And patient "2" has an observation with code "4548-4" and value 10.2 recorded on "2026-01-15"
    When measure "diabetes_a1c_control" is calculated for patients "1,2" for period "2025-04-01" to "2026-03-31"
    Then the calculation should produce a summary MeasureReport
    And the summary should show initial population count of 2
    And the summary should show numerator count of 1
    And the summary should have a performance rate of 0.5

  # ---------------------------------------------------------------------------
  # (c)(2) Test Procedure Step 4: FHIR API import endpoint
  # ---------------------------------------------------------------------------

  Scenario: Import via FHIR API endpoint
    Given the system is configured for FHIR API access
    And I have a valid SMART token with scope "system/*.write"
    When I POST a FHIR Measure resource to "/fhir/Measure/$import"
    Then the response status should be 200
    And the response should be a FHIR OperationOutcome with success

  # ---------------------------------------------------------------------------
  # Performance
  # ---------------------------------------------------------------------------

  Scenario: Measure import completes within acceptable time
    When a FHIR Measure resource is imported with timing
    Then the import should complete within 2 seconds
