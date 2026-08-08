# BPRM twin — scenario #1: Register a new patient
# HTTP:  POST /patients
# RPC:   BHDPTRPC REGISTER  ->  AG (IHS Patient Registration)  ->  ^DPT / ^AUPNPAT
# BPRM:  AgPatientRegisterEvent
# Disposition: sql-mutate -> reimpl  (BPRM raw-writes ^DPT/^AUPN*; reimplement via ^DIE/AG API so xrefs+audit fire)
@bprm_twin @registration
Feature: Register a new patient
  As a registration clerk at an IHS/Tribal facility
  I want to register a new patient into RPMS
  So that they have a chart with a facility Health Record Number (HRN) and can be scheduled and seen

  Background:
    Given I am authenticated as a registration clerk at service area "Portland"

  Scenario: Register a new American Indian/Alaska Native patient
    When I submit a registration with:
      | field             | value            |
      | name              | RAVEN,NORA       |
      | sex               | F                |
      | date_of_birth     | 1992-03-11       |
      | ssn               | 555-01-2345      |
      | tribe             | Yakama Nation    |
      | community         | Toppenish        |
      | classification    | Indian/Alaska Native |
      | eligibility       | Direct           |
    Then the registration succeeds
    And a new patient DFN is returned
    And a facility-scoped Health Record Number (HRN) is assigned and returned
    And the response includes the FileMan name "RAVEN,NORA"
    And an AG registration audit event is recorded

  Scenario: Reject a duplicate SSN
    Given a patient already exists with SSN "555-01-2345"
    When I submit a registration with:
      | field         | value       |
      | name          | RAVEN,DUP   |
      | sex           | F           |
      | date_of_birth | 1985-06-01  |
      | ssn           | 555-01-2345 |
    Then the registration is rejected with status 422
    And the error message mentions "SSN"

  Scenario: Broker unreachable surfaces as service-unavailable, not a data error
    Given the RPC broker is unreachable
    When I submit a valid registration
    Then the response status is 503
    And the error message is "Registration service unavailable"

  Scenario: Incomplete registration returns warnings but still creates the chart
    When I submit a registration missing the community field
    Then the registration succeeds
    And the response warnings include an incomplete-registration item for "COMMUNITY"
