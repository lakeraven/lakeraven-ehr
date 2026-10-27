Feature: Social Determinants of Health and SOGI (ONC § 170.315(a)(15))
  As a care coordinator
  I need to capture SDOH screening data and SOGI demographics
  So that I can address social risk factors and comply with USCDI v3

  Background:
    Given these RPMS demo patients:
      | dfn | name             | ssn       | dob        | sex |
      | 4   | DEMO,PATIENT ONE | 666010101 | 2001-01-01 | F   |

  # ==========================================================================
  # SDOH Screening Observations
  # ==========================================================================

  Scenario: Record housing status screening observation
    Given patient "4" has an observation with code "71802-3" and value "La" recorded on "2026-03-01"
    Then the observation for patient "4" with code "71802-3" should have category "social-history"
    And the observation should have LOINC code "71802-3"

  Scenario: Record food insecurity screening observation
    Given patient "4" has an observation with code "88122-7" and value "Often true" recorded on "2026-03-01"
    Then the observation for patient "4" with code "88122-7" should have category "social-history"

  Scenario: SDOH observations use US Core social-history profile
    Given patient "4" has an observation with code "71802-3" and value "La" recorded on "2026-03-01"
    Then the observation FHIR resource should have profile "http://hl7.org/fhir/us/core/StructureDefinition/us-core-observation-social-history"

  Scenario: Survey observations use US Core screening-assessment profile
    Given patient "4" has an observation with code "93025-5" and value "completed" recorded on "2026-03-01"
    And the observation has category "survey"
    Then the observation FHIR resource should have profile "http://hl7.org/fhir/us/core/StructureDefinition/us-core-observation-screening-assessment"

  # ==========================================================================
  # SOGI Data Elements in Patient
  # ==========================================================================

  Scenario: Patient has sexual orientation extension in FHIR
    Given patient "4" has sexual orientation "Straight or heterosexual"
    When I view the FHIR Patient resource for patient "4"
    Then the Patient resource should have a sexual orientation extension with value "Straight or heterosexual"

  Scenario: Patient has gender identity extension in FHIR
    Given patient "4" has gender identity "Identifies as female"
    When I view the FHIR Patient resource for patient "4"
    Then the Patient resource should have a gender identity extension with value "Identifies as female"
