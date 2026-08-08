# BPRM twin — scenario #14: Availability config + holidays
# HTTP:  PUT /clinics/:ien/availability_config
#        POST /clinics/:ien/holidays    DELETE /clinics/:ien/holidays/:date
# RPC:   BSDAPI / ^DIE on BSDX ACCESS BLOCK (9002018.3) + ACCESS TYPE (9002018.35)
# BPRM:  BsdSetAvailabilityConfig, BsdSetSchedulingAddHoliday, BsdSetSchedulingRemoveHoliday,
#        BsdSetSched* (6175/D9B7 triplets)
# Disposition: sql-mutate -> reimpl  (config writes must go through the scheduling API/^DIE)
@bprm_twin @scheduling @admin
Feature: Clinic availability configuration and holidays
  As a clinic scheduling administrator
  I want to configure a clinic's availability blocks and holidays
  So that the schedule offers correct open slots

  Background:
    Given a clinic "GENERAL MEDICINE" with IEN 15

  Scenario: Set a recurring availability block
    When I set clinic 15 availability to Monday-Friday "08:00" to "17:00" with slot length 20 minutes
    Then the availability config is saved
    And clinic 15 offers slots between "08:00" and "17:00" on a weekday

  Scenario: Add a clinic holiday
    When I add a holiday for clinic 15 on "2026-11-26" labeled "Thanksgiving"
    Then the holiday is saved
    And clinic 15 offers no open slots on "2026-11-26"

  Scenario: Remove a clinic holiday
    Given clinic 15 has a holiday on "2026-11-26"
    When I remove the holiday for clinic 15 on "2026-11-26"
    Then clinic 15 again offers open slots on "2026-11-26"
