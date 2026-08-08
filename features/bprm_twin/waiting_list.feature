# BPRM twin — scenario #13: Clinic waiting list
# HTTP:  GET  /clinics/:ien/waiting_list    POST /clinics/:ien/waiting_list
# RPC:   BSDWL* API on the waiting-list file; report via BMX query
# BPRM:  BsdReportWaitingList (read); BsdSetPatie* waitlist-set triplets (write)
# Disposition: read + sql-mutate -> reimpl  (waitlist adds must go through the BSDWL API/^DIE)
@bprm_twin @scheduling
Feature: Clinic waiting list
  As a scheduling clerk
  I want to add patients to a clinic waiting list and review it
  So that patients without an open slot are tracked and called when one opens

  Background:
    Given a registered patient with DFN 42 named "RAVEN,NORA"
    And a clinic "GENERAL MEDICINE" with IEN 15

  Scenario: Add a patient to the waiting list
    When I add patient 42 to the waiting list for clinic 15 with priority "routine" and reason "No open slots"
    Then the waiting-list add succeeds
    And clinic 15's waiting list includes patient 42

  Scenario: Report the waiting list
    Given clinic 15's waiting list has patients "RAVEN,NORA" and "BEGAY,MICHELLE"
    When I request the waiting-list report for clinic 15
    Then I see 2 patients on the list
