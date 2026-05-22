Feature: Open an active encounter
  As a clinical provider
  I need to open a patient's active encounter and see the hydrated chart context
  So that I can begin documenting the visit without manually fetching every section

  Background:
    Given a patient with DFN 26664
    And the patient has an active encounter with visit IEN 2090061
    And the encounter is at location "PS CLINICS" with provider "SAND,ASH"
    And the encounter is missing the "POV" and "E&M" components
    And the patient's brief header is name "TESTPATIENT,FIRST" sex "F" mrn "120305"
    And the patient has 2 vitals and 1 problem on file
    And the patient has 1 active allergy
    And the encounter has 1 active reminder

  Scenario: Provider opens an active encounter and gets hydrated chart context
    When the provider opens encounter 2090061 for patient 26664
    Then the open call should succeed
    And the encounter context should show location "PS CLINICS"
    And the encounter context should show provider "SAND,ASH"
    And the encounter context should show status "A"
    And the encounter context should list 2 missing components
    And the open result should include the patient brief header with name "TESTPATIENT,FIRST"
    And the open result should include 2 vitals
    And the open result should include 1 problem
    And the open result should include 1 allergy
    And the open result should include 1 reminder

  Scenario: Provider opens a non-existent encounter
    When the provider opens encounter 99999999 for patient 26664
    Then the open call should fail with a not-found result

  Scenario: Provider without view-patients capability is denied
    Given the requesting provider lacks the view-patients capability
    When the provider opens encounter 2090061 for patient 26664
    Then the open call should fail with a permission-denied result
