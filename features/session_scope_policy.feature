# frozen_string_literal: true

Feature: Session scope policy
  As the engine that decides what an authenticated clinician may reach
  I want SMART scopes derived solely from the security keys RPMS reported
  So that privilege comes from the RPMS site's own access decisions, never from a default

  # This is the seam between RPMS Kernel auth and SMART on FHIR. Sign-on
  # (features/authentication.feature) establishes WHO the user is; this
  # decides WHAT that user may reach. Keys arrive as the RPMS strings
  # ORWU USERKEYS returned, so these scenarios exercise the whole chain:
  # RPMS key name -> symbol -> scope string.

  # ===========================================================================
  # DENY BY DEFAULT
  # ===========================================================================

  Scenario: A clinician holding no security keys is granted nothing
    Given a clinician with no RPMS security keys
    When their session scopes are resolved
    Then the granted scopes should be empty

  Scenario: An RPMS key outside the registry never reaches the policy
    Given a clinician whose RPMS security keys are "ZZLOCAL SITE KEY"
    When their session scopes are resolved
    Then the granted scopes should be empty

  Scenario: A key the policy does not model grants nothing
    Given the resolved security keys include "zz_local_key", which the policy does not model
    When their session scopes are resolved
    Then the granted scopes should be empty

  Scenario: An unmodelled key adds nothing to the keys that are modelled
    Given the resolved security keys are "cprs_gui_chart" plus "zz_local_key", which the policy does not model
    When their session scopes are resolved
    Then the granted scopes should include:
      | user/Patient.read |
    And no scope should permit writing

  # ===========================================================================
  # EACH KEY GRANTS ONLY ITS OWN WORKFLOW
  # ===========================================================================

  Scenario: The chart key grants the chart read surface and no writes
    Given a clinician whose RPMS security keys are "OR CPRS GUI CHART"
    When their session scopes are resolved
    Then the granted scopes should include:
      | user/Patient.read     |
      | user/Observation.read |
      | user/Condition.read   |
      | user/Encounter.read   |
    And no scope should permit writing

  Scenario: The PRC supervisor key grants referral writes and coverage reads
    Given a clinician whose RPMS security keys are "PRCFA SUPERVISOR"
    When their session scopes are resolved
    Then the granted scopes should include:
      | user/ServiceRequest.read              |
      | user/ServiceRequest.write             |
      | user/Coverage.read                    |
      | user/CoverageEligibilityRequest.read  |
    And the granted scopes should not include:
      | user/Patient.read      |
      | user/Observation.read  |
      | user/Coverage.write    |

  Scenario: The PRC tech key grants referral reads without referral writes
    Given a clinician whose RPMS security keys are "PRCFA TECH"
    When their session scopes are resolved
    Then the granted scopes should include:
      | user/ServiceRequest.read |
    And no scope should permit writing

  Scenario: The dental key grants procedures but not the problem list
    Given a clinician whose RPMS security keys are "DENTP PROVIDER"
    When their session scopes are resolved
    Then the granted scopes should include:
      | user/Procedure.read  |
      | user/Procedure.write |
      | user/Encounter.read  |
    But the granted scopes should not include:
      | user/Condition.read  |
      | user/Condition.write |

  # ===========================================================================
  # KEYS COMBINE
  # ===========================================================================

  Scenario: Holding two keys grants the union of what each key owns
    Given a clinician whose RPMS security keys are "OR CPRS GUI CHART, PRCFA SUPERVISOR"
    When their session scopes are resolved
    Then the granted scopes should include:
      | user/Patient.read         |
      | user/ServiceRequest.read  |
      | user/ServiceRequest.write |
    And the only write scope granted should be "user/ServiceRequest.write"

  # ===========================================================================
  # SHAPE OF THE GRANT
  # ===========================================================================

  Scenario: A browser session is never granted a patient-compartment scope
    Given a clinician whose RPMS security keys are "OR CPRS GUI CHART, PRCFA SUPERVISOR, APCL VERIFY"
    When their session scopes are resolved
    Then every granted scope should begin with "user/"

  Scenario: No key in the policy can mint a patient-compartment scope
    Given a clinician holding every security key this engine models
    When their session scopes are resolved
    Then every granted scope should begin with "user/"
    And the granted scopes should not be empty

  # ===========================================================================
  # 42 CFR PART 2 — ASSERTED GAP, NOT A CONTROL (#494)
  # ===========================================================================
  #
  # The behavioural-health keys are inert on purpose. Resource-type scopes
  # cannot separate a PHQ-9 item-9 answer from a blood pressure: both arrive
  # as Observation. Granting the BH keys a resource type would look like Part 2
  # segmentation without being it, which is worse than an honest gap. These
  # scenarios pin the gap so it cannot be closed by accident — when record-level
  # segmentation lands, they are expected to fail and be rewritten.

  Scenario: The behavioural health provider key grants nothing today
    Given a clinician whose RPMS security keys are "BGMH PROVIDER"
    When their session scopes are resolved
    Then the granted scopes should be empty

  Scenario: The behavioural health supervisor key grants nothing today
    Given a clinician whose RPMS security keys are "BGMH SUPERVISOR"
    When their session scopes are resolved
    Then the granted scopes should be empty

  Scenario: Part 2 content travels with ordinary chart access
    Given a clinician whose RPMS security keys are "OR CPRS GUI CHART"
    When their session scopes are resolved
    Then the granted scopes should include:
      | user/Observation.read |
      | user/Condition.read   |
