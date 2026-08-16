# BPRM twin — scenario #4: Patient lookup / search / face sheet
# HTTP:  GET /patients?q=...   GET /patients/:dfn   GET /patients/:dfn/face_sheet
# RPC:   BHDPTRPC / patient_select + BMX search
# BPRM:  AgSearchPatient, AgGetPatientSearchResult, AgGetPatientFaceSheet,
#        AgGetPatientErrorsAndWarnings, AgGetPatientMbi (get)
# Disposition: read
@bprm_twin @registration @lookup
Feature: Patient lookup and face sheet
  As a front-desk clerk
  I want to find a patient and view their registration face sheet
  So that I can confirm identity and see outstanding registration issues

  Background:
    Given the following patients are registered:
      | dfn | hrn    | name           | dob        | sex | community          | tribe            |
      | 42  | 101226 | RAVEN,NORA     | 1992-03-11 | F   | Broken Rock City   | Broken Rock      |
      | 43  | 101227 | RAVEN,NOAH     | 1988-01-04 | M   | Broken Rock Falls  | Broken Rock      |
      | 44  | 118834 | BEGAY,MICHELLE | 1975-09-30 | F   | Tallgrass Town     | Tallgrass Nation |

  Scenario: Search by partial last name
    When I search patients for "RAVEN"
    Then I find 2 patients
    And the results include "RAVEN,NORA" and "RAVEN,NOAH"

  Scenario: Search by date of birth narrows the match
    When I search patients for "RAVEN" born on "1992-03-11"
    Then I find 1 patient
    And the result is "RAVEN,NORA"

  Scenario: Retrieve the face sheet for a patient
    When I request the face sheet for patient 42
    Then the face sheet shows name "RAVEN,NORA", community "Broken Rock City", tribe "Broken Rock"
    And the face sheet shows the facility Health Record Number "101226"

  Scenario: Face sheet surfaces registration errors and warnings
    Given patient 42 has an incomplete registration item for "ELIGIBILITY"
    When I request the face sheet for patient 42
    Then the face sheet warnings include an item for "ELIGIBILITY"

  Scenario: Lookup of an unknown DFN returns not found
    When I request patient 99999
    Then the response status is 404
