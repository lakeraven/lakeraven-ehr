Feature: Consent FHIR resource
  As a healthcare system
  I need to manage patient consent for proxy access and data sharing
  So that authorization decisions are enforceable and auditable

  # =============================================================================
  # CONSENT CREATION & VALIDATION
  # =============================================================================

  Scenario: Create a valid consent
    Given a consent with scope "patient-privacy" and status "active" for patient "1"
    Then the consent should be valid

  Scenario: Consent requires patient
    Given a consent without a patient
    Then the consent should be invalid
    And there should be a consent error on "patient_dfn"

  Scenario: Consent requires scope
    Given a consent without a scope for patient "1"
    Then the consent should be invalid
    And there should be a consent error on "scope"

  # =============================================================================
  # CONSENT STATUS
  # =============================================================================

  Scenario: Draft consent is not enforceable
    Given a consent with scope "patient-privacy" and status "draft" for patient "1"
    Then the consent should not be enforceable

  Scenario: Active consent is enforceable
    Given a consent with scope "patient-privacy" and status "active" for patient "1"
    Then the consent should be enforceable

  Scenario: Rejected consent is not enforceable
    Given a consent with scope "patient-privacy" and status "rejected" for patient "1"
    Then the consent should not be enforceable

  Scenario: Inactive consent is not enforceable
    Given a consent with scope "patient-privacy" and status "inactive" for patient "1"
    Then the consent should not be enforceable

  # =============================================================================
  # CONSENT SCOPE
  # =============================================================================

  Scenario: Patient privacy scope display
    Given a consent with scope "patient-privacy" and status "active" for patient "1"
    Then the scope display should be "Privacy Consent"

  Scenario: Treatment scope display
    Given a consent with scope "treatment" and status "active" for patient "1"
    Then the scope display should be "Treatment"

  Scenario: Research scope display
    Given a consent with scope "research" and status "active" for patient "1"
    Then the scope display should be "Research"

  # =============================================================================
  # PROVISION TYPES
  # =============================================================================

  Scenario: Permit provision authorizes access
    Given a consent with provision type "permit" for patient "1"
    Then the consent should permit access

  Scenario: Deny provision blocks access
    Given a consent with provision type "deny" for patient "1"
    Then the consent should deny access

  # =============================================================================
  # CONSENT VALIDITY PERIOD
  # =============================================================================

  Scenario: Consent within validity period
    Given a consent with period from "2025-01-01" to "2027-12-31" for patient "1"
    Then the consent should be within period

  Scenario: Consent before validity period starts
    Given a consent with period from "2099-01-01" to "2099-12-31" for patient "1"
    Then the consent should not be within period

  Scenario: Consent after validity period ends
    Given a consent with period from "2020-01-01" to "2020-12-31" for patient "1"
    Then the consent should not be within period

  # =============================================================================
  # FHIR SERIALIZATION
  # =============================================================================

  Scenario: FHIR Consent serialization includes resourceType
    Given a consent with scope "patient-privacy" and status "active" for patient "1"
    When I serialize the consent to FHIR
    Then the FHIR resourceType should be "Consent"

  Scenario: FHIR Consent includes patient reference
    Given a consent with scope "patient-privacy" and status "active" for patient "123"
    When I serialize the consent to FHIR
    Then the FHIR patient reference should be "Patient/123"

  Scenario: FHIR Consent includes scope coding
    Given a consent with scope "patient-privacy" and status "active" for patient "1"
    When I serialize the consent to FHIR
    Then the FHIR scope should include code "patient-privacy"

  Scenario: FHIR Consent includes category
    Given a consent with scope "patient-privacy" and status "active" for patient "1"
    When I serialize the consent to FHIR
    Then the FHIR category should be present

  Scenario: FHIR Consent includes provision
    Given a consent with scope "patient-privacy" and status "active" and provision "permit" for patient "1"
    When I serialize the consent to FHIR
    Then the FHIR provision type should be "permit"

  # =============================================================================
  # AUTHORIZATION LOGIC
  # =============================================================================

  Scenario: Active permit consent authorizes access
    Given a consent with scope "full_access" and status "active" and provision "permit" for patient "1"
    Then the consent should authorize access

  Scenario: Inactive consent does not authorize
    Given a consent with scope "full_access" and status "inactive" and provision "permit" for patient "1"
    Then the consent should not authorize access

  Scenario: Deny consent does not authorize
    Given a consent with scope "full_access" and status "active" and provision "deny" for patient "1"
    Then the consent should not authorize access

  Scenario: Consent allows specific permission
    Given a consent with scope "view_records" and status "active" and provision "permit" for patient "1"
    Then the consent should allow "view_records"
    And the consent should not allow "upload_docs"

  Scenario: Full access consent allows any permission
    Given a consent with scope "full_access" and status "active" and provision "permit" for patient "1"
    Then the consent should allow "view_records"
    And the consent should allow "upload_docs"
    And the consent should allow "message"
