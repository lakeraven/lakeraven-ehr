# frozen_string_literal: true

Feature: Referral origination
  As a clinician
  I need to create a referral that flows to the PRC engine for authorization
  So that the patient can receive purchased/referred care

  Scenario: Originate a referral with valid patient and service
    Given a patient with DFN "100" and name "DOE,JANE"
    And a requesting provider with IEN "201"
    When I originate a referral for:
      | service_requested    | Cardiology Consult  |
      | urgency              | ROUTINE             |
      | reason_for_referral  | Chest pain workup   |
    Then the referral should be created successfully
    And the referral should have a service request identifier
    And the origination result should include patient identifier "100"

  Scenario: Originate an urgent referral
    Given a patient with DFN "100" and name "DOE,JANE"
    And a requesting provider with IEN "201"
    When I originate a referral for:
      | service_requested    | Orthopedic Consult  |
      | urgency              | URGENT              |
      | reason_for_referral  | Fracture evaluation |
    Then the referral should be created successfully
    And the service request urgency should be "URGENT"

  Scenario: Originate a referral with missing service
    Given a patient with DFN "100" and name "DOE,JANE"
    And a requesting provider with IEN "201"
    When I originate a referral for:
      | service_requested    |                     |
      | urgency              | ROUTINE             |
    Then the referral should not be created
    And the origination error should mention "Service requested"

  Scenario: Originate a referral with missing provider
    Given a patient with DFN "100" and name "DOE,JANE"
    When I originate a referral without a provider for:
      | service_requested    | Cardiology Consult  |
      | urgency              | ROUTINE             |
    Then the referral should not be created

  Scenario: Origination result includes patient identifier for PRC handoff
    Given a patient with DFN "42" and name "SMITH,JOHN"
    And a requesting provider with IEN "201"
    When I originate a referral for:
      | service_requested    | Dermatology Consult  |
      | urgency              | ROUTINE              |
      | reason_for_referral  | Skin lesion eval     |
    Then the referral should be created successfully
    And the origination result should include patient identifier "42"

  Scenario: Origination with enrollment checker shows enrollment status
    Given a patient with DFN "100" and name "DOE,JANE"
    And the patient is enrolled in tribe "Test Tribe"
    And a requesting provider with IEN "201"
    When I originate a referral with enrollment check for:
      | service_requested    | Cardiology Consult  |
      | urgency              | ROUTINE             |
      | reason_for_referral  | Follow-up           |
    Then the referral should be created successfully
    And the origination result should show enrollment verified

  Scenario: Origination with enrollment checker shows non-enrolled status
    Given a patient with DFN "200" and name "SMITH,JOHN"
    And the patient is not enrolled
    And a requesting provider with IEN "201"
    When I originate a referral with enrollment check for:
      | service_requested    | Dermatology Consult  |
      | urgency              | ROUTINE              |
      | reason_for_referral  | Skin eval            |
    Then the referral should be created successfully
    And the origination result should show enrollment not verified

  Scenario: Origination without enrollment checker omits enrollment status
    Given a patient with DFN "100" and name "DOE,JANE"
    And a requesting provider with IEN "201"
    When I originate a referral for:
      | service_requested    | Cardiology Consult  |
      | urgency              | ROUTINE             |
      | reason_for_referral  | Routine follow-up   |
    Then the referral should be created successfully
    And the origination result should not include enrollment status
