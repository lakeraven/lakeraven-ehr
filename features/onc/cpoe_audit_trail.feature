@onc
Feature: CPOE Audit Trail
  As a compliance officer
  I want every CPOE operation to produce an immutable audit record
  So that the prescribe/order/result lifecycle is fully traceable

  Background:
    Given a patient exists with DFN "12345"
    And a provider exists with DUZ "789"

  # =============================================================================
  # ORDER CREATION AUDIT
  # =============================================================================

  Scenario: Medication order creation is audited
    When the provider creates a medication order for "Lisinopril 10mg"
    Then an audit event should exist with subtype "medication_order_created"
    And the audit event action should be "C"
    And the audit event agent should be "789"

  Scenario: Lab order creation is audited
    When the provider creates a lab order:
      | field       | value                |
      | test_name   | Complete Blood Count |
      | test_code   | 58410-2              |
    Then an audit event should exist with subtype "lab_order_created"
    And the audit event action should be "C"

  Scenario: Imaging order creation is audited
    When the provider creates an imaging order:
      | field       | value       |
      | study_type  | Chest X-Ray |
      | body_site   | Chest       |
    Then an audit event should exist with subtype "imaging_order_created"
    And the audit event action should be "C"

  # =============================================================================
  # ORDER SIGNING AUDIT
  # =============================================================================

  Scenario: Signing a medication order is audited with content hash
    Given a draft medication order exists for "Lisinopril 10mg"
    When the provider signs the order
    Then an audit event should exist with subtype "medication_order_signed"
    And the audit event action should be "E"
    And the audit event should include a content hash

  Scenario: Signing a lab order is audited
    Given a draft lab order exists for "CBC"
    When the provider signs the order
    Then an audit event should exist with subtype "lab_order_signed"

  # =============================================================================
  # ORDER CANCELLATION AUDIT
  # =============================================================================

  Scenario: Cancelling an order is audited with reason
    Given a draft medication order exists for "Lisinopril 10mg"
    When the provider cancels the order with reason "contraindicated interaction"
    Then an audit event should exist with subtype "medication_order_cancelled"
    And the audit event action should be "D"
    And the audit event should include reason "contraindicated interaction"

  # =============================================================================
  # FULL LIFECYCLE CHAIN
  # =============================================================================

  Scenario: Full order lifecycle produces a queryable audit chain
    Given a draft medication order exists for "Lisinopril 10mg"
    When the provider signs the order
    Then the audit trail for the order should have 3 events
    And the audit trail should show "medication_order_created" then "medication_order_signed"
