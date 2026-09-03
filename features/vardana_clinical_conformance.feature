# frozen_string_literal: true

@vardana_conformance
Feature: Vardana source-system clinical-data conformance
  As a chronic-care program platform (Vardana)
  I need the FHIR API to satisfy the clinical half of the source-system profile
  So that a program can read a patient's clinical baseline safely

  # Spec: Vardana Source System Profile v1 — §3 (resources), §4 (search),
  # §5 (data quality), §7 (checklist items 3-10). Auth (items 1-2) is owned
  # by the parallel auth PR.
  #
  # Gateway rows use the REAL decorated-measurement shape the rpms-rpc
  # Measurement reads return (rpms-rpc PR #188): the V MEASUREMENT IEN is
  # the identity, units are source-supplied (BEHOVM2 VUNITS), and the
  # parent visit's SERVICE CATEGORY (#9000010 field .07) carries the
  # capture modality.

  Background:
    Given I am authenticated with SMART-on-FHIR

  # ---------------------------------------------------------------------------
  # Checklist item 10 — Provenance: office-measured vs not office-measured.
  # The service category records the encounter's capture MODALITY (telecom /
  # telemedicine / historical / chart review), NOT an informant — so a
  # non-office value is represented as "not office-measured, modality X,
  # informant not recorded", never as an invented who=Patient assertion.
  # ---------------------------------------------------------------------------
  Scenario: Office-measured and telecom-captured values are distinguishable via Provenance
    Given patient "1" has a clinic-measured blood pressure and a telecom-captured weight
    When I request GET "/lakeraven-ehr/Provenance" with params:
      | patient | 1 |
    Then the response resourceType should be "Bundle"
    And the bundle should contain a Provenance targeting the blood pressure with agent type "author"
    And the bundle should contain a Provenance targeting the weight with no agent type
    And the weight Provenance should carry source modality "T" without asserting an informant
    And every Provenance should be valid FHIR R4

  Scenario: Provenance is searchable by target observation alone
    Given the telecom-captured weight measurement is readable by IEN
    When I request the Provenance for the weight by target only
    Then the bundle should contain exactly 1 entry
    And the weight Provenance should carry source modality "T" without asserting an informant

  Scenario: Provenance is readable by its id alone
    Given the telecom-captured weight measurement is readable by IEN
    When I request the Provenance resource by its id
    Then the response resourceType should be "Provenance"
    And the Provenance target should reference the weight observation

  Scenario: A value whose capture context is unknown yields no Provenance
    Given patient "1" has a vital with no recorded service category
    When I request GET "/lakeraven-ehr/Provenance" with params:
      | patient | 1 |
    Then the response resourceType should be "Bundle"
    And the bundle should contain exactly 0 entries

  # ---------------------------------------------------------------------------
  # Checklist item 7 / §4 — search parameters and pagination
  # ---------------------------------------------------------------------------
  Scenario: Condition search filters to active problems and an inactive row stays inactive
    Given patient "1" has an active problem and an inactive problem
    When I request GET "/lakeraven-ehr/Condition" with params:
      | patient         | 1      |
      | clinical-status | active |
    Then the response resourceType should be "Bundle"
    And the bundle should contain exactly 1 entry
    And every Condition in the bundle should have clinical status "active"
    And the active Condition should be the hypertension problem

  Scenario: MedicationRequest search filters to active medications
    Given patient "1" has an active medication and a discontinued medication
    When I request GET "/lakeraven-ehr/MedicationRequest" with params:
      | patient | 1      |
      | status  | active |
    Then the response resourceType should be "Bundle"
    And the bundle should contain exactly 1 entry
    And every MedicationRequest in the bundle should have status "active"

  Scenario: Observation search by LOINC code, date floor, and newest-first sort
    Given patient "1" has weight observations recorded on "2025-01-05", "2025-01-12" and "2025-01-20"
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient | 1            |
      | code    | 29463-7      |
      | date    | ge2025-01-10 |
      | _sort   | -date        |
    Then the response resourceType should be "Bundle"
    And the bundle should contain exactly 2 entries
    And every Observation in the bundle should have code "29463-7"
    And every Observation effectiveDateTime should be on or after "2025-01-10"
    And the bundle observations should be sorted newest first

  Scenario: Encounter search by date floor with newest-first sort
    Given patient "1" has encounters on "2024-12-01", "2025-01-10" and "2025-02-01"
    When I request GET "/lakeraven-ehr/Encounter" with params:
      | patient | 1            |
      | date    | ge2025-01-01 |
      | _sort   | -date        |
    Then the response resourceType should be "Bundle"
    And the bundle should contain exactly 2 entries
    And every Encounter in the bundle should have a class and a period
    And the bundle encounters should be sorted newest first

  Scenario: Pagination returns a complete set across more than one page
    Given patient "1" has 5 weight observations on consecutive days
    When I page through "/lakeraven-ehr/Observation" for patient "1" with _count "2"
    Then I should have followed at least 2 next links
    And the pages should collectively contain exactly 5 distinct observation ids
    And each page should contain at most 2 entries

  Scenario: A _count of zero returns the total with no entries
    Given patient "1" has 5 weight observations on consecutive days
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient | 1 |
      | _count  | 0 |
    Then the response resourceType should be "Bundle"
    And the bundle total should be 5
    And the bundle should contain exactly 0 entries

  # ---------------------------------------------------------------------------
  # Checklist items 5, 6, 8, 9 — §5 data quality
  # ---------------------------------------------------------------------------
  Scenario: Observations return with LOINC codes, source units, and clinical effective dates
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient | 1 |
    Then the response resourceType should be "Bundle"
    And every quantitative Observation should have a LOINC-coded code
    And every quantitative Observation should have a value with unit and unit system
    And every Observation should have an effectiveDateTime

  Scenario: A blood pressure round-trips with both components and correct units
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient | 1       |
      | code    | 85354-9 |
    Then the bundle should contain exactly 1 entry
    And the blood pressure should have component "8480-6" with value 120.0 and unit "mm[Hg]"
    And the blood pressure should have component "8462-4" with value 80.0 and unit "mm[Hg]"
    And both blood pressure components should use unit system "http://unitsofmeasure.org"

  Scenario: A value without a source unit is dropped, not guessed
    Given patient "1" has a weight measurement with no source unit
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient | 1 |
    Then the response resourceType should be "Bundle"
    And the bundle should contain exactly 0 entries

  Scenario: Resource ids are stable across two reads separated by a data change
    Given patient "1" has weight observations recorded on "2025-01-05", "2025-01-12" and "2025-01-20"
    When I read the observation ids for patient "1"
    And a new weight observation is recorded for patient "1" on "2025-02-01"
    And I read the observation ids for patient "1" again
    Then every originally read observation id should still be present with the same id

  Scenario: Two same-minute readings of the same type keep distinct ids
    Given patient "1" has two weight measurements taken in the same minute
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient | 1 |
    Then the bundle should contain exactly 2 entries
    And the observation ids in the bundle should all be distinct and non-blank

  Scenario: A corrected value is distinguishable from the original
    Given patient "1" has a blood pressure entered in error and a corrected replacement
    When I request GET "/lakeraven-ehr/Observation" with params:
      | patient | 1 |
    Then the bundle should contain exactly 2 entries
    And exactly 1 Observation in the bundle should have status "entered-in-error"
    And exactly 1 Observation in the bundle should have status "final"

  # ---------------------------------------------------------------------------
  # Checklist item 3 — Patient telecom (PATIENT #2 field .131 via the
  # registered DDR GETS ENTRY DATA — RpmsRpc::Patient.contact)
  # ---------------------------------------------------------------------------
  Scenario: Patient read returns a usable telephone contact
    Given patient "1" has a residence phone number "555-0142" on file
    When I request GET "/lakeraven-ehr/Patient/1"
    Then the response resourceType should be "Patient"
    And the patient telecom should include a phone with value "555-0142"
