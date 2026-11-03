@in_clinic_consent
Feature: In-clinic consent on a locked patient tablet
  As clinic staff
  I need patients to sign versioned consent forms on a clinic tablet
  So that signed consents land on the chart with a witness and an audit trail

  Background:
    Given demo clinical seeds are loaded
    And patient "DEMOPATIENT,MARA" is the active patient context
    And the clinician is signed in with consent write scopes for in-clinic signing

  Scenario: Patient signs a treatment consent on the clinic tablet
    Given the clinician starts the "bh-treatment" consent handover
    When the patient signs the kiosk consent form
    Then a signed consent exists for the patient with template version witness and signature
    And the chart consent list shows the consent as Active

  Scenario: The patient-facing screen exposes nothing else
    Given the clinician starts the "bh-treatment" consent handover
    Then the kiosk shows only the consent template and patient name and date of birth
    And the kiosk has no navigation search or chart links
    When the patient signs the kiosk consent form
    And the clinician unlocks the kiosk with their access and verify codes
    Then the clinician returns to the patient consent list

  Scenario: A signed consent cannot be edited
    Given the clinician starts the "bh-treatment" consent handover
    And the patient signs the kiosk consent form
    And the clinician unlocks the kiosk with their access and verify codes
    When the clinician attempts to edit the signed consent
    Then the edit is refused and the stored consent is unchanged
    When the clinician records a revocation with a synthetic reason
    Then the chart consent list shows the consent as Revoked

  Scenario: Every access is audited
    Given the clinician opens the patient consent list
    When the clinician starts the "telehealth" consent handover
    And the patient signs the kiosk consent form with typed name "Testpatient, Beta"
    And the clinician unlocks the kiosk with their access and verify codes
    And the clinician records a revocation with a synthetic reason
    Then audit events exist for consent list view kiosk view sign and revoke
    And no audit event contains the signature image or typed signer name
