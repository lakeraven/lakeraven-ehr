Feature: Patient search
  As a SMART-on-FHIR client
  I need to search for patients in the EHR
  So that I can resolve a patient context for a clinical workflow

  Background:
    Given the EHR adapter is the in-memory mock
    And the current tenant is "tnt_test"
    And the current facility is "fac_main"
    And the following patients are registered at facility "fac_main":
      | display_name | date_of_birth | gender |
      | DOE,JOHN     | 1980-01-15    | male   |
      | SMITH,JANE   | 1975-06-20    | female |
      | JOHNSON,BOB  | 1990-03-10    | male   |
    And the following patients are registered at facility "fac_other":
      | display_name | date_of_birth | gender |
      | OTHER,PERSON | 1985-12-05    | male   |

  Scenario: Search by full name
    When I search for patients by name "DOE,JOHN"
    Then the search returns 1 patient
    And the result includes a patient with display name "DOE,JOHN"

  Scenario: Search by partial last name
    When I search for patients by name "JOH"
    Then the search returns 2 patients
    And the result includes a patient with display name "DOE,JOHN"
    And the result includes a patient with display name "JOHNSON,BOB"

  Scenario: Search returns opaque patient identifiers
    When I search for patients by name "DOE,JOHN"
    Then every result has an opaque patient_identifier prefixed with "pt_"
    And no result exposes a backend-native DFN

  Scenario: Empty result is a valid empty array, not an error
    When I search for patients by name "NONEXISTENT"
    Then the search returns 0 patients
    And the search succeeds without raising

  Scenario: Search is scoped to the current facility
    When I search for patients by name "PERSON"
    Then the search returns 0 patients

  Scenario: Search across all facilities in the tenant when no facility is set
    Given the current facility is unset
    When I search for patients by name "PERSON"
    Then the search returns 1 patient

  Scenario: Search fails loud when no tenant context is set
    Given the current tenant is unset
    When I search for patients by name "DOE,JOHN"
    Then the search raises a missing-tenant-context error
