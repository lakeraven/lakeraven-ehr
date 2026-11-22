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

  # What this scenario shows is what the app sends. It does not show RPMS
  # confirming the entry: RPMS here is a stand-in that answers success. RPMS
  # confirming a patient-detail entry is not yet shown on any build. The only
  # live capture of this entry shape (rpms-rpc
  # test/fixtures/captured_replies/busa-log.yml, patient_detail/1) was taken
  # from release bcer-9.0-20261119-f67498c-ydb, which files the summary,
  # refuses the patient-detail row and answers 0^. An entry RPMS does not
  # confirm is recorded locally as "BUSA entry not confirmed"; the next
  # scenario is that captured reply.
  Scenario: A saved edit sends one BUSA entry naming the patient and the action, and RPMS takes the user from the session
    Given a registration clerk is signed on as RPMS user 207
    And RPMS holds registered patient 990031
    When the clerk saves a change to the demographics of patient 990031
    Then the change is saved
    And RPMS receives exactly 1 BUSA security audit entry
    And the BUSA entry names patient 990031
    And the BUSA entry records a patient edit described as "Registration: demographics edited"
    And the BUSA entry carries no user, because RPMS takes the user from the session

  # The answer of release bcer-9.0-20261119-f67498c-ydb to this exact entry
  # shape, as captured live: rpms-rpc
  # test/fixtures/captured_replies/busa-log.yml, patient_detail/1 (input
  # P|E|SYNTH RPC|Synthetic demographic update|990031). The reply the app is
  # handed is the gem's own parse of the captured raw return, not a hand-built
  # one. The edit is already saved in RPMS, so the clerk's flow is unchanged
  # and the unconfirmed entry is recorded locally.
  #
  # Where the capture comes from, and what it does not cover:
  #   - The capture's user was a demo user given the BUSARPC option by hand on
  #     a throwaway container. No published demo persona holds BUSARPC.
  #   - On this repo's pinned build (bcer-9.0-20261113-3f5487a-ydb, 3f5487a) no
  #     BUSA reply has been captured.
  #   - A user without BUSARPC is expected to be refused the context, which the
  #     app records as not confirmed with the error class as the reason.
  Scenario: The captured reply of bcer-9.0-20261119-f67498c-ydb to a patient-detail entry is recorded as not confirmed
    Given a registration clerk is signed on as RPMS user 207
    And RPMS holds registered patient 990031
    And RPMS answers the BUSA entry with the captured reply of bcer-9.0-20261119-f67498c-ydb for a patient-detail row
    When the clerk saves a change to the demographics of patient 990031
    Then the change is saved
    And RPMS receives exactly 1 BUSA security audit entry
    And the BUSA entry names patient 990031
    And exactly 1 local "BUSA entry not confirmed" row names patient 990031

  # A form saved as RPMS already holds it is not an edit: nothing is sent to
  # RPMS, so there is nothing to audit. The change saved after it is the
  # control: the same stand-in for RPMS then sees one update and one entry.
  Scenario: A save that changes nothing leaves no BUSA entry
    Given a registration clerk is signed on as RPMS user 207
    And RPMS holds registered patient 990031
    When the clerk saves the demographics of patient 990031 without changing anything
    Then the clerk is returned to patient 990031
    And RPMS is asked to change nothing
    And RPMS receives exactly 0 BUSA security audit entries
    When the clerk saves a change to the demographics of patient 990031
    Then the change is saved
    And RPMS receives exactly 1 BUSA security audit entry

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
