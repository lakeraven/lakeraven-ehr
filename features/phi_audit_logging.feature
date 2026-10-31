Feature: PHI Audit Logging
  As a compliance officer
  I need all access to Protected Health Information (PHI) to be logged
  So I can meet HIPAA § 164.312(b) audit requirements

  # =============================================================================
  # AUDIT EVENTS FROM FHIR API ACCESS
  # =============================================================================

  Scenario: FHIR Patient search creates an audit event
    Given I am authenticated with SMART-on-FHIR
    And no audit events exist
    # A Patient search identifies its subject with _id. The `patient` search
    # parameter is for resources that REFERENCE a patient, so `?patient=1` on
    # /Patient named no compartment, and a patient-bound token issuing a
    # search that names no patient is a cross-patient read -- refused,
    # correctly. PatientsController binds on params[:_id].
    When I request GET "/lakeraven-ehr/Patient" with params:
      | _id | 1 |
    Then the response status should be 200
    And an audit event should exist with action "R" and entity type "Patient"

  Scenario: FHIR AllergyIntolerance search creates an audit event
    Given I am authenticated with SMART-on-FHIR
    And no audit events exist
    When I request GET "/lakeraven-ehr/AllergyIntolerance" with params:
      | patient | 1 |
    Then the response status should be 200
    # The audit names the PATIENT, not the resource type. A patient-scoped
    # search names the patient whose chart was read: recording the resource
    # type instead left /audit-review?entity=<dfn> and the HIPAA 164.528
    # accounting export EMPTY for a chart that had just been opened. This
    # scenario asserted that earlier behaviour (AuditableClinicalAccess owns
    # the rule and derives both halves together).
    And an audit event should exist with action "R" and entity type "Patient"

  Scenario: 404 request creates audit event with failure outcome
    Given I am authenticated with SMART-on-FHIR
    And no audit events exist
    When I request GET "/lakeraven-ehr/AllergyIntolerance/nonexistent"
    Then the response status should be 404
    And an audit event should exist with outcome "4"

  # =============================================================================
  # IMMUTABILITY
  # =============================================================================

  Scenario: Audit events cannot be updated
    Given an audit event exists in the database
    When I try to update the audit event
    Then the update should be rejected as immutable

  Scenario: Audit events cannot be deleted
    Given an audit event exists in the database
    When I try to delete the audit event
    Then the deletion should be rejected as immutable

  # =============================================================================
  # AUDIT EVENT STRUCTURE
  # =============================================================================

  Scenario: Audit events include required HIPAA fields
    Given I am authenticated with SMART-on-FHIR
    And no audit events exist
    # A Patient search identifies its subject with _id. The `patient` search
    # parameter is for resources that REFERENCE a patient, so `?patient=1` on
    # /Patient named no compartment, and a patient-bound token issuing a
    # search that names no patient is a cross-patient read -- refused,
    # correctly. PatientsController binds on params[:_id].
    When I request GET "/lakeraven-ehr/Patient" with params:
      | _id | 1 |
    Then the most recent audit event should have event_type "rest"
    And the most recent audit event should have a recorded timestamp
