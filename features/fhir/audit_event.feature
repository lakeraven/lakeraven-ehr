# frozen_string_literal: true

Feature: AuditEvent FHIR resource
  As a compliance officer
  I need to represent audit events as FHIR resources
  So that PHI access logging is interoperable

  Scenario: Audit event with read action
    Given an audit event with action "R" for entity "Patient" "100"
    Then the audit event should be a read action
    And the audit event action display should be "Read"

  Scenario: Audit event with create action
    Given an audit event with action "C" for entity "Patient" "100"
    Then the audit event should be a create action
    And the audit event action display should be "Create"

  Scenario: Audit event with update action
    Given an audit event with action "U" for entity "Patient" "100"
    Then the audit event should be an update action

  Scenario: Audit event with delete action
    Given an audit event with action "D" for entity "Patient" "100"
    Then the audit event should be a delete action

  Scenario: Audit event with execute action
    Given an audit event with action "E" for entity "ValueSet" "gpra-diabetes-dx"
    Then the audit event should be an execute action

  Scenario: Successful outcome
    Given an audit event with outcome "0" for entity "Patient" "100"
    Then the audit event should be successful
    And the audit event outcome display should be "Success"

  Scenario: Minor failure outcome
    Given an audit event with outcome "4" for entity "Patient" "100"
    Then the audit event should be a minor failure

  Scenario: Serious failure outcome
    Given an audit event with outcome "8" for entity "Patient" "100"
    Then the audit event should be a serious failure

  Scenario: Major failure outcome
    Given an audit event with outcome "12" for entity "Patient" "100"
    Then the audit event should be a major failure

  Scenario: Event type display
    Given a rest audit event with action "R" for entity "Patient" "100"
    Then the audit event type display should be "RESTful Operation"

  Scenario: Security event type
    Given a security audit event with action "R" for entity "Patient" "100"
    Then the audit event type display should be "Security"

  Scenario: Entity presence check
    Given an audit event with action "R" for entity "Patient" "100"
    Then the audit event should have an entity

  Scenario: Audit event without entity identifier
    Given an audit event with action "R" and entity type "Patient" but no identifier
    Then the audit event should not have an entity

  Scenario: FHIR AuditEvent includes resourceType
    Given an audit event with action "R" for entity "Patient" "100"
    When I serialize the audit event to FHIR
    Then the FHIR resourceType should be "AuditEvent"

  Scenario: FHIR AuditEvent includes action
    Given an audit event with action "R" for entity "Patient" "100"
    When I serialize the audit event to FHIR
    Then the FHIR audit event action should be "R"

  Scenario: FHIR AuditEvent includes outcome
    Given an audit event with outcome "0" for entity "Patient" "100"
    When I serialize the audit event to FHIR
    Then the FHIR audit event outcome should be "0"

  Scenario: FHIR AuditEvent includes entity reference
    Given an audit event with action "R" for entity "Patient" "100"
    When I serialize the audit event to FHIR
    Then the FHIR audit event entity should reference "Patient/100"

  Scenario: FHIR AuditEvent includes agent
    Given an audit event with action "R" for entity "Patient" "100" by agent "201"
    When I serialize the audit event to FHIR
    Then the FHIR audit event agent should include "201"

  Scenario: FHIR AuditEvent type coding
    Given a rest audit event with action "R" for entity "Patient" "100"
    When I serialize the audit event to FHIR
    Then the FHIR audit event type code should be "rest"

  Scenario: Export event type
    Given an export audit event with action "R" for entity "Patient" "100"
    Then the audit event type display should be "Export"

  Scenario: Import event type
    Given an import audit event with action "C" for entity "Patient" "100"
    Then the audit event type display should be "Import"

  Scenario: Query event type
    Given a query audit event with action "E" for entity "Patient" "100"
    Then the audit event type display should be "Query"

  Scenario: User authentication event type
    Given a user audit event with action "E" for entity "Session" "user-201"
    Then the audit event type display should be "User Authentication"

  Scenario: Application event type
    Given an application audit event with action "E" for entity "System" "startup"
    Then the audit event type display should be "Application"

  Scenario: FHIR AuditEvent includes outcome description
    Given an audit event with outcome "4" and description "Resource not found" for entity "Patient" "999"
    When I serialize the audit event to FHIR
    Then the FHIR audit event outcome description should be "Resource not found"

  Scenario: FHIR AuditEvent agent includes network address
    Given an audit event with action "R" for entity "Patient" "100" by agent "201" from "192.168.1.1"
    When I serialize the audit event to FHIR
    Then the FHIR audit event agent network should be "192.168.1.1"

  Scenario: FHIR AuditEvent with no agent omits agent array
    Given an audit event with action "R" for entity "Patient" "100"
    When I serialize the audit event to FHIR
    Then the FHIR audit event agents should be empty

  Scenario: FHIR AuditEvent with no entity omits entity array
    Given an audit event with action "R" and entity type "Patient" but no identifier
    When I serialize the audit event to FHIR
    Then the FHIR audit event entities should be empty
