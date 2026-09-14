@behavioral_health @pending
Feature: Behavioral-health access-to-care clock
  As a behavioral-health program supervisor
  I need the intervals from first contact to evaluation, plan, and review to be tracked
  So that access standards are met and reported rather than discovered afterwards

  # Specification ahead of implementation (#499). #475 stores the plan
  # review-due date; nothing computes the clock, surfaces it, or covers the
  # first-contact-to-evaluation leg. Intervals are site/program configuration
  # (L2/L3), not engine constants — certified-clinic criteria are one profile
  # among several. Steps are intentionally undefined rather than stubbed (#484).

  Background:
    Given the following patients exist:
      | dfn | first_name | last_name | dob        | sex |
      | 1   | Alice      | Anderson  | 1980-05-15 | F   |
    And the access standard for the program is:
      | interval              | value           |
      | initial_evaluation    | 10 business days|
      | treatment_plan_due    | 60 days         |
      | plan_review_interval  | 6 months        |
    And the site observes the following holidays:
      | date       |
      | 2026-11-26 |

  # ---------------------------------------------------------------------------
  # First contact to initial evaluation
  # ---------------------------------------------------------------------------

  Scenario: The clock starts at first contact
    When patient "1" makes first contact on "2026-10-01"
    Then the initial evaluation for patient "1" should be due on "2026-10-15"

  Scenario: The interval is counted in business days
    When patient "1" makes first contact on "2026-11-16"
    Then the initial evaluation due date should exclude weekends
    And the initial evaluation due date should exclude the site holiday "2026-11-26"

  Scenario: An evaluation inside the interval closes the leg as met
    Given patient "1" made first contact on "2026-10-01"
    When an initial evaluation is completed on "2026-10-09"
    Then the initial evaluation interval should be recorded as met

  Scenario: An evaluation after the interval closes the leg as missed
    Given patient "1" made first contact on "2026-10-01"
    When an initial evaluation is completed on "2026-10-20"
    Then the initial evaluation interval should be recorded as missed
    And the recorded elapsed business days should be 13

  Scenario: An open leg past its due date shows as overdue without a completing event
    Given patient "1" made first contact on "2026-10-01"
    And no initial evaluation has been completed
    When the date is "2026-10-16"
    Then the initial evaluation for patient "1" should be "overdue"

  # ---------------------------------------------------------------------------
  # Treatment plan and review
  # ---------------------------------------------------------------------------

  Scenario: The treatment plan clock starts at the initial evaluation
    Given an initial evaluation for patient "1" was completed on "2026-10-09"
    Then the treatment plan for patient "1" should be due on "2026-12-08"

  Scenario: The review clock starts at the treatment plan
    Given a treatment plan for patient "1" was signed on "2026-12-01"
    Then the plan review for patient "1" should be due on "2027-06-01"

  Scenario: Completing a review restarts the review clock
    Given a plan review for patient "1" was due on "2027-06-01"
    When a plan review is completed on "2027-05-20"
    Then the next plan review for patient "1" should be due on "2027-11-20"

  # ---------------------------------------------------------------------------
  # Where it shows up
  # ---------------------------------------------------------------------------

  Scenario: Approaching and overdue states appear on the clinical worklist
    Given patient "1" has an initial evaluation due in 2 business days
    Then the worklist should show patient "1" as "approaching"

  Scenario: Overdue cases are visible without running a report
    Given patient "1" has an initial evaluation that is 3 business days overdue
    When I open the clinical worklist
    Then patient "1" should appear in the overdue group

  Scenario: The chart shows the open clock for the patient in context
    Given patient "1" has an open treatment plan clock
    When I open the chart for patient "1"
    Then the chart should show the treatment plan due date

  # ---------------------------------------------------------------------------
  # Configuration, not constants
  # ---------------------------------------------------------------------------

  Scenario: A program with different intervals uses its own numbers
    Given the access standard for the program sets "initial_evaluation" to "5 business days"
    When patient "1" makes first contact on "2026-10-01"
    Then the initial evaluation for patient "1" should be due on "2026-10-08"

  Scenario: A patient enrolled in two programs is measured against each
    Given patient "1" is enrolled in a program requiring evaluation in 10 business days
    And patient "1" is enrolled in a program requiring evaluation in 5 business days
    When patient "1" makes first contact on "2026-10-01"
    Then the access clock should track both due dates independently

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  Scenario: The program report shows intervals achieved, not only intervals set
    Given the program has 10 closed initial-evaluation legs
    And 8 of them were completed within the standard
    When the access report is run for the program
    Then the report should show 8 of 10 met
    And the report should show the median elapsed business days
