# BPRM twin — scenario #2: Edit patient demographics
# HTTP:  PATCH /patients/:dfn
# RPC:   VAFCPTED + LR/AG-faithful path  ->  ^DIE on ^DPT (PATIENT #2)
# BPRM:  AgPatientUpdateEvent, AgSetCorrectPatientName, AgSetPatientCellNumber,
#        AgSetPatientDateOfDeath, AgSetPatientMbi (set path)
# Disposition: sql-mutate -> reimpl  (BPRM patches individual ^DPT fields raw; use ^DIE)
@bprm_twin @registration
Feature: Edit patient demographics and eligibility
  As a registration clerk
  I want to correct and update a patient's demographic record
  So that the chart stays accurate and audited

  Background:
    Given a registered patient with DFN 42 named "RAVEN,NORA"

  Scenario: Correct a misspelled patient name
    When I update patient 42 with:
      | field | value       |
      | name  | RAVEN,NORAH |
    Then the update succeeds
    And patient 42 now has name "RAVEN,NORAH"
    And a FileMan audit entry records the name change

  Scenario: Update a patient's cell phone number
    When I update patient 42 with:
      | field       | value        |
      | cell_phone  | 509-555-0142 |
    Then the update succeeds
    And patient 42 now has cell phone "509-555-0142"

  Scenario: Record a date of death
    When I update patient 42 with:
      | field         | value      |
      | date_of_death | 2026-07-20 |
    Then the update succeeds
    And patient 42 is marked deceased on "2026-07-20"

  Scenario: Set the Medicare Beneficiary Identifier
    When I update patient 42 with:
      | field | value       |
      | mbi   | 1EG4-TE5-MK73 |
    Then the update succeeds
    And patient 42 has MBI "1EG4-TE5-MK73"
