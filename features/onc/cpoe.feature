@onc
Feature: Computerized Provider Order Entry (CPOE)
  As a prescribing provider
  I want to enter orders electronically
  So that orders are accurate, checked for safety, and documented

  ONC § 170.315(a)(1) - CPOE Medications
  ONC § 170.315(a)(2) - CPOE Laboratory
  ONC § 170.315(a)(3) - CPOE Diagnostic Imaging

  Background:
    Given a patient exists with DFN "12345"
    And a provider exists with DUZ "789"

  # =============================================================================
  # MEDICATION ORDERS - § 170.315(a)(1)
  # =============================================================================

  Scenario: Create a medication order
    When the provider creates a medication order:
      | field              | value                          |
      | medication         | Lisinopril 10mg                |
      | dosage             | Take 1 tablet by mouth daily   |
      | route              | oral                           |
      | frequency          | QD                             |
      | quantity           | 30                             |
      | refills            | 3                              |
    Then the order should be created with status "draft"
    And the order should reference the patient
    And the order should reference the provider as requester

  Scenario: Medication order triggers interaction check
    Given the patient has an active medication "Warfarin 5mg"
    When the provider creates a medication order for "Ibuprofen 400mg"
    Then the order should include interaction alerts
    And the order status should be "draft" pending review

  Scenario: Medication order with no interactions proceeds
    When the provider creates a medication order for "Lisinopril 10mg"
    And there are no interaction alerts
    Then the order should be created with status "draft"

  Scenario: Sign a medication order
    Given a draft medication order exists for "Lisinopril 10mg"
    When the provider signs the order
    Then the order status should be "active"
    And the order intent should be "order"

  Scenario: Reject a medication order due to interactions
    Given the patient has an active medication "Oxycodone 5mg"
    And a draft medication order exists for "Diazepam 5mg"
    When the provider cancels the order with reason "contraindicated interaction"
    Then the order status should be "cancelled"

  # =============================================================================
  # LABORATORY ORDERS - § 170.315(a)(2)
  # =============================================================================

  Scenario: Create a laboratory order
    When the provider creates a lab order:
      | field              | value                          |
      | test_name          | Complete Blood Count           |
      | test_code          | 58410-2                        |
      | priority           | routine                        |
      | clinical_reason    | Annual screening               |
    Then the lab order should be created with status "draft"
    And the lab order category should be "laboratory"

  Scenario: Create a stat lab order
    When the provider creates a lab order:
      | field              | value                          |
      | test_name          | Basic Metabolic Panel          |
      | test_code          | 51990-0                        |
      | priority           | stat                           |
      | clinical_reason    | Acute renal assessment         |
    Then the lab order should have priority "stat"

  Scenario: Sign a lab order
    Given a draft lab order exists for "Complete Blood Count"
    When the provider signs the order
    Then the lab order status should be "active"

  # =============================================================================
  # IMAGING ORDERS - § 170.315(a)(3)
  # =============================================================================

  Scenario: Create an imaging order
    When the provider creates an imaging order:
      | field              | value                          |
      | study_type         | Chest X-Ray                    |
      | body_site          | Chest                          |
      | laterality         | bilateral                      |
      | clinical_reason    | Cough, rule out pneumonia      |
      | priority           | routine                        |
    Then the imaging order should be created with status "draft"
    And the imaging order category should be "imaging"

  Scenario: Sign an imaging order
    Given a draft imaging order exists for "Chest X-Ray"
    When the provider signs the order
    Then the imaging order status should be "active"
