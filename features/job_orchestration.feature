Feature: Background job orchestration with audit logging
  As a compliance officer
  I need background jobs to create audit trails
  So that I can track system operations for HIPAA compliance

  Scenario: Successful job creates audit event
    Given an auditable job that succeeds
    When the job is performed
    Then an audit event should exist with outcome "0" and entity type "Job"
    And the audit event action should be "E"
    And the audit event type should be "application"

  Scenario: Failed job creates failure audit event with sanitized error
    Given an auditable job that raises "Patient DFN: 12345 not found"
    When the job is performed and fails
    Then an audit event should exist with outcome "8" and entity type "Job"
    And the failure audit event should have a sanitized outcome description

  Scenario: Job failure audit event does not contain PHI
    Given an auditable job that raises "SSN 123-45-6789 lookup failed for SMITH,JOHN"
    When the job is performed and fails
    Then the failure outcome description should not contain "123-45-6789"
    And the failure outcome description should not contain "SMITH,JOHN"

  Scenario: Clinical FHIR access creates read audit event
    Given I am authenticated with SMART-on-FHIR
    And no audit events exist
    When I request GET "/lakeraven-ehr/Patient" with params:
      | patient | 1 |
    Then the most recent audit event should have action "R"
    And the most recent audit event should have event_type "rest"

  Scenario: Clinical FHIR access records network address
    Given I am authenticated with SMART-on-FHIR
    And no audit events exist
    When I request GET "/lakeraven-ehr/Patient" with params:
      | patient | 1 |
    Then the most recent audit event should have a network address
