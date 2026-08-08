# BPRM twin — scenario #12: A patient's appointments + routing slip
# HTTP:  GET /patients/:dfn/appointments   GET /patients/:dfn/routing_slip?date=...
# RPC:   ORWPT APPTLST + BMX query on BSDX APPOINTMENT; BsdRoutingSlip
# BPRM:  BsdGetPatientFutureApptsReport, BsdReportPatientFutureAppts, BsdRoutingSlip,
#        BsdReportRoutingSlip, BsdReportCancelledAppointment
# Disposition: read
@bprm_twin @scheduling
Feature: A patient's appointments and routing slip
  As a clerk
  I want to see a patient's upcoming appointments and print a routing slip
  So that the patient knows their schedule and the visit has a check-in document

  Background:
    Given a registered patient with DFN 42 named "RAVEN,NORA"
    And patient 42 has appointments:
      | clinic           | time             | status    |
      | GENERAL MEDICINE | 2026-08-20 09:00 | scheduled |
      | DENTAL           | 2026-09-02 13:30 | scheduled |
      | BEHAVIORAL HEALTH| 2026-07-01 10:00 | cancelled |

  Scenario: List future appointments
    Given the current date is "2026-08-08"
    When I request the future appointments for patient 42
    Then I see 2 appointments
    And the appointments are "GENERAL MEDICINE" and "DENTAL"

  Scenario: List cancelled appointments
    When I request the cancelled appointments for patient 42
    Then I see 1 appointment in clinic "BEHAVIORAL HEALTH"

  Scenario: Generate a routing slip for a day's visit
    When I request the routing slip for patient 42 on "2026-08-20"
    Then the routing slip lists the "GENERAL MEDICINE" appointment at "09:00"
    And the routing slip shows patient name "RAVEN,NORA"
