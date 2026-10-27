@behavioral_health
Feature: Psychotherapy visit coding is structured and duration-validated
  As a behavioral-health clinician
  I need visit-level psychotherapy CPT selection tied to documented face-to-face time
  So that claims receive a defensible procedure code and duration without guessing

  # Family (90846/90847) and group (90853) psychotherapy are out of scope until the
  # engine models those encounter kinds; this feature covers psychiatric diagnostic
  # evaluation (90791) and individual psychotherapy (90832/90834/90837) only.

  Background:
    Given a patient with DFN 8801
    And the patient has an active encounter with visit IEN 2090061
    And the documenting provider has DUZ 2843

  Scenario: The default code offered for a new behavioral-health episode is 90791
    When I ask for the default psychotherapy CPT code for a new behavioral-health episode
    Then the offered psychotherapy CPT code should be "90791"

  Scenario: Psychiatric diagnostic evaluation does not require documented duration
    When I document psychotherapy visit coding for encounter kind "psychiatric_diagnostic_evaluation" with duration minutes absent
    Then the psychotherapy visit coding should be resolved
    And the psychotherapy CPT code should be "90791"
    And the claim procedure handoff should include procedure code "90791" and duration minutes absent

  Scenario Outline: Individual psychotherapy duration selects the CPT time band
    When I document psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration <minutes> minutes
    Then the psychotherapy visit coding should be resolved
    And the psychotherapy CPT code should be "<code>"

    Examples:
      | minutes | code   |
      | 16      | 90832  |
      | 37      | 90832  |
      | 38      | 90834  |
      | 52      | 90834  |
      | 53      | 90837  |

  Scenario Outline: Individual psychotherapy below minimum or invalid duration is not reportable
    When I document psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration <minutes> minutes
    Then the psychotherapy visit coding should not be resolved
    And the psychotherapy visit coding blocking reason should be "<reason>"

    Examples:
      | minutes | reason                  |
      | 15      | below_minimum_duration  |
      | 0       | invalid_duration        |
      | -5      | invalid_duration        |

  Scenario: Missing duration on individual psychotherapy must not propose a code
    When I document psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration minutes absent
    Then the psychotherapy visit coding should not be resolved
    And the psychotherapy visit coding blocking reason should be "missing_duration"
    And there should be no psychotherapy CPT code proposed

  Scenario: A behavioral-health visit cannot be finalized until coding is resolved
    Given psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration 15 minutes is on file
    When the provider attempts to finalize the behavioral-health visit
    Then the visit finalization should fail with error "coding_unresolved"
    And the encounter should remain in progress

  Scenario: Finalizing succeeds when psychotherapy coding is resolved
    Given psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration 45 minutes is on file
    When the provider attempts to finalize the behavioral-health visit
    Then the visit finalization should succeed
    And the encounter should be finished

  Scenario: Duration outside the clinician-selected code band is rejected
    When I document psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration 30 minutes and selected CPT code "90837"
    Then the psychotherapy visit coding should not be resolved
    And the psychotherapy visit coding blocking reason should be "selection_inconsistent_with_duration"
    When the provider attempts to finalize the behavioral-health visit
    Then the visit finalization should fail with error "coding_unresolved"
    And the encounter should remain in progress

  Scenario: Consistent clinician selection flows to billing as the selected code
    When I document psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration 45 minutes and selected CPT code "90834"
    Then the psychotherapy visit coding should be resolved
    And the psychotherapy CPT code should be "90834"
    And the claim procedure handoff should include procedure code "90834" and duration minutes 45

  Scenario: Clinician-selected CPT outside the allowed psychotherapy set is refused
    When I document psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration 45 minutes and selected CPT code "90853"
    Then the psychotherapy visit coding should be refused with blocking reason "disallowed_cpt_code"

  Scenario: Psychiatric diagnostic evaluation code cannot be selected on individual psychotherapy
    When I document psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration 45 minutes and selected CPT code "90791"
    Then the psychotherapy visit coding should be refused with blocking reason "cpt_code_incompatible_with_encounter_kind"

  Scenario: Individual psychotherapy requires duration even when a CPT code is selected
    When I document psychotherapy visit coding for encounter kind "individual_psychotherapy" with duration minutes absent and selected CPT code "90834"
    Then the psychotherapy visit coding should not be resolved
    And the psychotherapy visit coding blocking reason should be "missing_duration"
