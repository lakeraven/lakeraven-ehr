# BPRM twin — scenario #8: Mark an appointment as no-show
# HTTP:  POST /appointments/:id/no_show   (and DELETE to undo)
# RPC:   BSDX NOSHOW  ->  NOSHOW^BSDX31  ->  $$CANCEL^BSDAPI  ->  ^SC no-show node
# NOTE:  BSDX NOSHOW's success signal is INVERTED: result 1 = success, 0 = error
#        (opposite polarity to BSDX ADD NEW APPOINTMENT's empty-error convention).
# BPRM:  (no dedicated BPRM SP; BSDX-native no-show)
# Disposition: fm-write
@bprm_twin @scheduling
Feature: Mark an appointment as no-show
  As a scheduling clerk
  I want to flag a patient who did not arrive as a no-show
  So that clinic utilization reporting is accurate

  Background:
    Given a registered patient with DFN 42
    And patient 42 has appointment 7001 in clinic 15 at "2026-08-20 09:00"

  Scenario: Flag a no-show after the appointment time
    Given the current time is "2026-08-20 09:30"
    When I mark appointment 7001 as no-show
    Then the no-show is recorded
    And appointment 7001 status is "no-show"

  Scenario: Undo a no-show
    Given appointment 7001 is marked no-show
    When I undo the no-show on appointment 7001
    Then appointment 7001 status is "scheduled"

  Scenario: Cannot no-show a future appointment
    Given the current time is "2026-08-20 08:00"
    When I mark appointment 7001 as no-show
    Then the request is rejected with status 422
    And the error message mentions "before the appointment time"
