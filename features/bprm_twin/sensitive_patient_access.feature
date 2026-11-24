@sensitive_patient_access
Feature: Sensitive-patient access when a clinician opens a record
  BPRM 6.0 checks sensitive-patient access every time a record is opened
  (AG_CheckSPTAccessQ, AG_CheckAndSetSilentSPTAccessQ, AG_SetSPTAccessQ).
  lakeraven-ehr asks RPMS the same question before it opens a record:
  DG SENSITIVE RECORD ACCESS (PTSEC^DGSEC4), and, once the user has
  acknowledged the warning, DG SENSITIVE RECORD BULLETIN (NOTICE^DGSEC4),
  which writes the DG SECURITY LOG (#38.11) entry and sends the bulletin.

  This slice is the clinician's deliberate "open this patient's record" step
  only (lakeraven-ehr#613). Search, the chart, registration and scheduling
  follow in later slices.

  Background:
    Given a clinician is signed in to open patient records

  # rpms-ux story id: not yet assigned (lakeraven-ehr#565)
  Scenario: A user without access is warned and must acknowledge before the record opens
    Given RPMS answers that patient 3 is a sensitive record the user must acknowledge
    And RPMS will write the security log entry and send the bulletin for patient 3
    When the clinician opens the record of patient 3
    Then the sensitive record warning from RPMS is shown with a way to acknowledge it
    And the warning shows no details of patient 3
    And no patient record is open
    And no sensitive record bulletin was sent
    When the clinician acknowledges the sensitive record warning
    Then the record of patient 3 is open
    And RPMS was asked to write the security log entry and send the bulletin for patient 3

  # rpms-ux story id: not yet assigned (lakeraven-ehr#565)
  Scenario: A user with access opens a sensitive record silently
    Given RPMS answers that patient 3 is a sensitive record the user may open without acknowledging
    When the clinician opens the record of patient 3
    Then the record of patient 3 is open
    And RPMS was asked whether patient 3 is a sensitive record
    And no sensitive record bulletin was sent

  # rpms-ux story id: not yet assigned (lakeraven-ehr#565)
  Scenario: A record that is not sensitive opens without a warning
    Given RPMS answers that patient 1 is not a sensitive record
    When the clinician opens the record of patient 1
    Then the record of patient 1 is open
    And RPMS was asked whether patient 1 is a sensitive record
    And no sensitive record bulletin was sent

  # rpms-ux story id: not yet assigned (lakeraven-ehr#565)
  Scenario: A user RPMS denies does not get the record
    Given RPMS answers that access to patient 3 is denied
    When the clinician opens the record of patient 3
    Then the open is refused with RPMS's reason
    And no patient record is open
    And no sensitive record bulletin was sent

  # rpms-ux story id: not yet assigned (lakeraven-ehr#565)
  Scenario: A record does not open when RPMS does not answer
    Given RPMS does not answer whether patient 1 is a sensitive record
    When the clinician opens the record of patient 1
    Then the open is refused
    And no patient record is open
    And no sensitive record bulletin was sent
