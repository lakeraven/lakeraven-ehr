# frozen_string_literal: true

Feature: ValueSet audit trail
  As a compliance officer
  I need to track all ValueSet operations
  So that terminology usage is auditable

  Scenario: Record ValueSet access
    Given a ValueSet audit service
    When I record access to ValueSet "gpra-diabetes-dx" by agent "provider-201"
    Then the audit history for "gpra-diabetes-dx" should have 1 entry
    And the most recent entry should have activity "EXECUTE"

  Scenario: Record ValueSet expansion
    Given a ValueSet audit service
    When I record expansion of ValueSet "gpra-diabetes-dx" by agent "provider-201" with 15 codes
    Then the audit history for "gpra-diabetes-dx" should have 1 entry
    And the most recent entry should have reason "HRESCH"

  Scenario: Record code validation
    Given a ValueSet audit service
    When I record validation of code "E11.9" against ValueSet "gpra-diabetes-dx" by agent "provider-201" with result true
    Then the audit history for "gpra-diabetes-dx" should have 1 entry
    And the most recent entry should have reason "HACCRD"

  Scenario: Record ValueSet creation
    Given a ValueSet audit service
    When I record creation of ValueSet "custom-measure-01" by agent "admin-101"
    Then the audit history for "custom-measure-01" should have 1 entry
    And the most recent entry should have activity "CREATE"

  Scenario: Record ValueSet update
    Given a ValueSet audit service
    When I record update of ValueSet "custom-measure-01" by agent "admin-101"
    Then the audit history for "custom-measure-01" should have 1 entry
    And the most recent entry should have activity "UPDATE"

  Scenario: Record ValueSet deletion
    Given a ValueSet audit service
    When I record deletion of ValueSet "custom-measure-01" by agent "admin-101"
    Then the audit history for "custom-measure-01" should have 1 entry
    And the most recent entry should have activity "DELETE"

  Scenario: Agent history across ValueSets
    Given a ValueSet audit service
    When I record access to ValueSet "gpra-diabetes-dx" by agent "provider-201"
    And I record access to ValueSet "gpra-hypertension-dx" by agent "provider-201"
    Then the agent history for "provider-201" should have 2 entries

  Scenario: Usage statistics
    Given a ValueSet audit service
    When I record access to ValueSet "gpra-diabetes-dx" by agent "provider-201"
    And I record expansion of ValueSet "gpra-diabetes-dx" by agent "provider-202" with 15 codes
    And I record validation of code "E11.9" against ValueSet "gpra-diabetes-dx" by agent "provider-201" with result true
    Then the usage stats for "gpra-diabetes-dx" should show 3 total operations
    And the usage stats should show 2 unique agents

  Scenario: History ordered by most recent first
    Given a ValueSet audit service
    When I record access to ValueSet "gpra-diabetes-dx" by agent "provider-201"
    And I record expansion of ValueSet "gpra-diabetes-dx" by agent "provider-202" with 10 codes
    Then the first history entry for "gpra-diabetes-dx" should be most recent

  Scenario: Creation with source document
    Given a ValueSet audit service
    When I record creation of ValueSet "imported-vs" by agent "admin-101" from source "doc-001"
    Then the most recent entry for "imported-vs" should reference source "doc-001"

  Scenario: Expansion tracks code count and cache status
    Given a ValueSet audit service
    When I record expansion of ValueSet "gpra-diabetes-dx" by agent "provider-201" with 15 codes cached
    Then the expansion metadata should show 15 codes
    And the expansion metadata should show cached true
