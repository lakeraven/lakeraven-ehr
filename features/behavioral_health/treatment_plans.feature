@treatment_plans
Feature: Treatment plans with review-due compliance dates (#475)
  As a therapist and clinical supervisor
  I need treatment-plan review deadlines tracked as data
  So that reviews happen on time and audits pass

  # The plan is stored in the engine's own database, not in RPMS file
  # 9002011.56. See the DIVERGENCE FLAG on Lakeraven::EHR::TreatmentPlan.

  Background:
    Given patient 123 has an active behavioral-health episode

  Scenario: Creating a treatment plan sets review-due dates
    When the therapist establishes a treatment plan on "2026-12-01"
    Then a 60-day progress-review due date of "2027-01-30" is stored on the plan
    And an end-of-treatment review due date of "2027-06-01" can be recorded

  Scenario: A plan is established by a designated provider
    When a treatment plan is established with no designated provider
    Then the plan is not stored
    And the error names the designated provider

  Scenario: Overdue reviews appear on the worklist
    Given a treatment plan established on "2026-10-01" with no progress review
    And a treatment plan for patient 456 established on "2026-12-01" with no progress review
    When the worklist is viewed on "2026-12-15"
    Then the "reviews overdue" preset shows a count of 1
    And the "reviews overdue" preset lists the plan for patient 123

  Scenario: A review due today is not yet overdue
    Given a treatment plan established on "2026-10-01" with no progress review
    When the worklist is viewed on "2026-11-30"
    Then the "reviews overdue" preset shows a count of 0

  Scenario: An ended plan does not count as overdue
    Given a treatment plan established on "2026-10-01" with no progress review
    And the plan ended on "2026-11-15"
    When the worklist is viewed on "2026-12-15"
    Then the "reviews overdue" preset shows a count of 0

  Scenario: Concurring supervisor is captured
    Given a treatment plan established on "2026-12-01" with no progress review
    When supervising clinician "77777" concurs with the plan at "2026-12-02T09:30:00Z"
    Then the plan records the concurrence by "77777" at "2026-12-02T09:30:00Z"

  Scenario: The designated provider cannot concur with their own plan
    Given a treatment plan established on "2026-12-01" with no progress review
    When the designated provider concurs with the plan
    Then the concurrence is refused

  Scenario: Completing a review resets the cadence
    Given a treatment plan established on "2026-10-01" with no progress review
    When the therapist documents the 60-day progress review on "2026-11-20"
    Then the next review due date is "2027-01-19"
    And the plan keeps a record of the review on "2026-11-20"

  Scenario: A reviewed plan leaves the overdue worklist
    Given a treatment plan established on "2026-10-01" with no progress review
    When the therapist documents the 60-day progress review on "2026-12-10"
    And the worklist is viewed on "2026-12-15"
    Then the "reviews overdue" preset shows a count of 0
