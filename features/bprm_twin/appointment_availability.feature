# BPRM twin — scenario #6: Clinic availability / open slots
# HTTP:  GET /clinics/:ien/availability?from=...&to=...
# RPC:   BMX query on BSDX ACCESS BLOCK (9002018.3) + ^SC availability
# BPRM:  BsdGetSchedulingAvailableSlots, BsdGetSchedulingAccessBlocks,
#        BsdGetSchedulingConfigAccessBlocks
# Disposition: read
@bprm_twin @scheduling
Feature: Clinic availability and open slots
  As a scheduling clerk
  I want to see a clinic's open slots and access blocks
  So that I can offer the patient a time

  Background:
    Given a clinic "GENERAL MEDICINE" with IEN 15
    And clinic 15 has an access block "ROUTINE" on "2026-08-20" from "08:00" to "12:00"
    And clinic 15 has a booked appointment at "2026-08-20 09:00" for 20 minutes

  Scenario: List open slots for a day
    When I request availability for clinic 15 on "2026-08-20"
    Then the open slots exclude "2026-08-20 09:00"
    And the open slots include "2026-08-20 08:00"

  Scenario: List configured access blocks
    When I request the access-block configuration for clinic 15
    Then I see an access block "ROUTINE" covering "08:00" to "12:00"

  Scenario: A day with no access blocks has no open slots
    When I request availability for clinic 15 on "2026-08-21"
    Then there are no open slots
