@bprm_twin
Feature: Session and audit behaviours carried over from BPRM 6.0
  As a site moving its front desk from BPRM 6.0 to lakeraven-ehr
  I need the app to do the session-level things BPRM did
  So that RPMS holds the same security audit trail, times and facility as before

  # lakeraven-ehr#617. BPRM 6.0 procedure -> RPC:
  #   Core_SetBusaAuditLogQ         -> BUSA LOG SECURITY AUDIT ENTRY
  #   Core_GetDatabaseTimeQ         -> ORWU DT
  #   Core_SetSessionVariablesQ     -> CIANBRPC DIVSET
  #   AG_SendBenefitCaseAssignMsgQ  -> BGU MAILMAN MESSAGE
  #
  # Not carried over, and why:
  #   CoreUtility_SetBprmInstallInfo
  #     BPRM install bookkeeping. lakeraven-ehr is not a BPRM install, so there
  #     is nothing for it to record.
  #   Core_PrintReport
  #     The web app renders reports itself. Only "print to an RPMS device"
  #     would need CIAVUTIO PRINT, and the app does not offer that.
  #   Core_SetRemotePatientContextQ (CIANBEVT BCAST)
  #     Only applies alongside a VueCentric EHR, which shares patient context
  #     over that broadcast. lakeraven-ehr does not run beside one.
  #
  # First slice: the BUSA entry, for one audited action, a saved registration
  # edit. The scenarios tagged @pending specify what is not built yet; their
  # steps are left undefined rather than stubbed.

  Scenario: Each audited action leaves one BUSA entry with the user, the patient and the action
    Given a registration clerk is signed on as RPMS user 207
    And RPMS holds registered patient 990031
    When the clerk saves a change to the demographics of patient 990031
    Then the change is saved
    And RPMS receives exactly 1 BUSA security audit entry
    And the BUSA entry names patient 990031
    And the BUSA entry records a patient edit described as "Registration: demographics edited"
    And the BUSA entry leaves the user to RPMS, which records the signed-on user

  # Waits on: the app choosing which of its own timestamps come from RPMS. No
  # app timestamp path reads the server clock (ORWU DT) yet.
  @pending
  Scenario: Times recorded by the app come from the server
    Given the RPMS server clock and the app clock disagree
    When the app records the time of an action
    Then the recorded time is the RPMS server time

  # Waits on: rpms-rpc offering a public mid-session division set (CIANBRPC
  # DIVSET). Client#bind_division is private, so the app cannot switch.
  @pending
  Scenario: Switching division changes the facility on subsequent writes
    Given a user who may sign on to more than one division
    When the user switches to another division
    Then the next write to RPMS is filed under that division's facility

  # Waits on: benefits-case assignment, which the app does not have yet. The
  # message (BGU MAILMAN MESSAGE) is sent when a case is assigned.
  @pending
  Scenario: Assigning a benefits case delivers a MailMan message to the assignee
    Given a benefits case with no coordinator assigned
    When the case is assigned to a benefits coordinator
    Then that coordinator receives a MailMan message about the case
