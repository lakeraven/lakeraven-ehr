# BPRM twin — scenario #11: List a clinic's schedule for a day
# HTTP:  GET /clinics/:ien/schedule?date=YYYY-MM-DD
# RPC:   BMX query on ^SC S-nodes / BSDX APPOINTMENT (9002018.4)
# BPRM:  BsdReportClinicSchedule, BsdClinicScheduleReport, BsdGetSched* (12E2/764F/8FC9 triplets)
# Disposition: read
@bprm_twin @scheduling
Feature: List a clinic's daily schedule
  As a provider or clerk
  I want to see the day's appointments for a clinic
  So that I know who is scheduled and their status

  Background:
    Given a clinic "GENERAL MEDICINE" with IEN 15
    And clinic 15 has appointments on "2026-08-20":
      | time  | patient        | status      |
      | 09:00 | RAVEN,NORA     | scheduled   |
      | 09:20 | RAVEN,NOAH     | checked-in  |
      | 09:40 | BEGAY,MICHELLE | no-show     |

  Scenario: View the clinic schedule for a date
    When I request the schedule for clinic 15 on "2026-08-20"
    Then I see 3 appointments in time order
    And the 09:20 appointment shows patient "RAVEN,NOAH" with status "checked-in"

  Scenario: Cancelled appointments are excluded by default
    Given appointment for "RAVEN,NORA" at "09:00" is cancelled
    When I request the schedule for clinic 15 on "2026-08-20"
    Then I see 2 appointments
    And "RAVEN,NORA" is not listed

  Scenario: Include cancelled appointments when requested
    Given appointment for "RAVEN,NORA" at "09:00" is cancelled
    When I request the schedule for clinic 15 on "2026-08-20" including cancelled
    Then "RAVEN,NORA" is listed with status "cancelled"
