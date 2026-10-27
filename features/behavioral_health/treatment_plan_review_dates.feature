@treatment_plans @behavioral_health
Feature: Treatment plan progress-review due dates
  As a behavioral-health clinician
  I need treatment plans to carry review due dates I can query for compliance
  So that overdue progress reviews are visible before they are discovered in an audit

  # Implements lakeraven-ehr#475. Review intervals are program/site configuration
  # (L2/L3), not engine constants — compatible with the access clock in #499,
  # which is intentionally not implemented here.

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
    And the behavioral health program "bh_outpatient" has review intervals:
      | interval                | value    |
      | progress_review         | 60 days  |
      | end_of_treatment_review | 6 months |

  Scenario: Establishing a plan computes the first progress-review due date from configuration
    When a treatment plan for patient "1" in program "bh_outpatient" is established on "2026-01-01" by provider "301"
    Then the plan's next progress-review due date should be "2026-03-02"
    And the plan's end-of-treatment review due date should be "2026-07-01"

  Scenario: A program with a different progress-review interval uses its own cadence
    Given the behavioral health program "bh_intensive" has review intervals:
      | interval                | value    |
      | progress_review         | 90 days  |
      | end_of_treatment_review | 6 months |
    When a treatment plan for patient "1" in program "bh_intensive" is established on "2026-01-01" by provider "301"
    Then the plan's next progress-review due date should be "2026-04-01"

  Scenario: Completing a progress review records it and recomputes the next due date
    Given a treatment plan for patient "1" in program "bh_outpatient" was established on "2026-01-01" by provider "301"
    When a progress review for the plan is completed on "2026-02-15" by provider "301"
    Then the plan's next progress-review due date should be "2026-04-16"
    And the plan should have 1 recorded progress review on "2026-02-15"

  Scenario: A plan due today is not overdue
    Given a treatment plan for patient "1" in program "bh_outpatient" was established on "2026-01-01" by provider "301"
    When the date is "2026-03-02"
    Then the plan should not be progress-review overdue

  Scenario: A plan due yesterday is overdue
    Given a treatment plan for patient "1" in program "bh_outpatient" was established on "2026-01-01" by provider "301"
    When the date is "2026-03-03"
    Then the plan should be progress-review overdue

  Scenario: A late review moves the next due date forward from the review date
    Given a treatment plan for patient "1" in program "bh_outpatient" was established on "2026-01-01" by provider "301"
    And a progress review for the plan was completed on "2026-03-15" by provider "301"
    Then the plan's next progress-review due date should be "2026-05-14"
    When the date is "2026-05-14"
    Then the plan should not be progress-review overdue

  Scenario: Supervisor concurrence records who and when
    Given a treatment plan for patient "1" in program "bh_outpatient" was established on "2026-01-01" by provider "301"
    When supervisor "302" concurs with the plan on "2026-01-05"
    Then the plan's concurrence should be by supervisor "302" on "2026-01-05"

  Scenario: The designated provider cannot concur as their own supervisor
    Given a treatment plan for patient "1" in program "bh_outpatient" was established on "2026-01-01" by provider "301"
    When supervisor "301" attempts to concur with the plan on "2026-01-05"
    Then the concurrence should be refused

  Scenario: Overdue progress reviews are queryable
    Given the behavioral health program "bh_intensive" has review intervals:
      | interval                | value   |
      | progress_review         | 60 days |
      | end_of_treatment_review | 6 months |
    And a treatment plan for patient "1" in program "bh_outpatient" was established on "2026-01-01" by provider "301"
    And a treatment plan for patient "1" in program "bh_intensive" was established on "2025-11-01" by provider "301"
    When the date is "2026-03-03"
    Then the progress-review overdue count should be 2
