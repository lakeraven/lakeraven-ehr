# frozen_string_literal: true

Feature: Session scope policy
  As the engine that decides what an authenticated clinician may reach
  I want SMART scopes derived solely from the security keys RPMS reported
  So that privilege comes from the RPMS site's own access decisions, never from a default

  # This is the seam between RPMS Kernel auth and SMART on FHIR. Sign-on
  # (features/authentication.feature) establishes WHO the user is; this decides
  # WHAT that user may reach. Keys arrive as the RPMS strings ORWU USERKEYS
  # returned, so these scenarios run the whole chain: RPMS key name -> symbol ->
  # scope string.
  #
  # EVERY KEY IS PINNED EXHAUSTIVELY, not sampled. An earlier draft asserted a
  # few positives per key and left the rest open; an adversarial review showed
  # prc_tech could be widened to coverage reads, eligibility_verify could mint
  # user/Patient.write, dental could inherit most of the chart, and
  # CHART_READ_TYPES could be gutted to two entries — all with every scenario
  # green. Exact-set assertions are what close that: any widening OR narrowing
  # of any key fails here.

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
    Then the granted scopes should be exactly what "cprs_gui_chart" alone grants

  # ===========================================================================
  # EVERY KEY, EXHAUSTIVELY
  # ===========================================================================
  #
  # Each key grants only what its own RPMS workflow owns. These are exact sets:
  # a scope absent from the table is a scope the key must not confer.

  Scenario: OR CPRS GUI CHART grants the chart read surface and nothing else
    Given a clinician whose RPMS security keys are "OR CPRS GUI CHART"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/AllergyIntolerance.read |
      | user/CarePlan.read           |
      | user/Condition.read          |
      | user/Consent.read            |
      | user/DiagnosticReport.read   |
      | user/Encounter.read          |
      | user/Immunization.read       |
      | user/Location.read           |
      | user/Medication.read         |
      | user/MedicationRequest.read  |
      | user/Observation.read        |
      | user/Organization.read       |
      | user/Patient.read            |
      | user/Practitioner.read       |
      | user/Procedure.read          |
      | user/Provenance.read         |

  Scenario: PRCFA SUPERVISOR grants referrals read-write and coverage read-only
    Given a clinician whose RPMS security keys are "PRCFA SUPERVISOR"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/Coverage.read                   |
      | user/CoverageEligibilityRequest.read |
      | user/ServiceRequest.read             |
      | user/ServiceRequest.write            |

  Scenario: BPRC MANAGER grants the same referral surface as the supervisor
    Given a clinician whose RPMS security keys are "BPRC MANAGER"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/Coverage.read                   |
      | user/CoverageEligibilityRequest.read |
      | user/ServiceRequest.read             |
      | user/ServiceRequest.write            |

  Scenario: PRCFA TECH reads referrals only, with no coverage and no writes
    Given a clinician whose RPMS security keys are "PRCFA TECH"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/ServiceRequest.read |

  Scenario: BGOZ CHS APPROVE acts on referrals without reaching coverage
    Given a clinician whose RPMS security keys are "BGOZ CHS APPROVE"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/ServiceRequest.read  |
      | user/ServiceRequest.write |

  Scenario: BGOZ CHS CLERK reads referrals without acting on them
    Given a clinician whose RPMS security keys are "BGOZ CHS CLERK"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/ServiceRequest.read |

  Scenario: GMRC MGR manages consults through the referral surface
    Given a clinician whose RPMS security keys are "GMRC MGR"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/ServiceRequest.read  |
      | user/ServiceRequest.write |

  Scenario: APCL VERIFY reaches coverage only, never the chart
    Given a clinician whose RPMS security keys are "APCL VERIFY"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/Coverage.read                    |
      | user/Coverage.write                   |
      | user/CoverageEligibilityRequest.read  |
      | user/CoverageEligibilityRequest.write |

  Scenario: SD SUPERVISOR schedules encounters without writing locations
    Given a clinician whose RPMS security keys are "SD SUPERVISOR"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/Encounter.read  |
      | user/Encounter.write |
      | user/Location.read   |

  Scenario: DENTP PROVIDER grants procedures, never the problem list or the chart
    Given a clinician whose RPMS security keys are "DENTP PROVIDER"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/Encounter.read   |
      | user/Procedure.read   |
      | user/Procedure.write  |

  Scenario: DENTP SUPERVISOR grants the same dental surface as the provider
    Given a clinician whose RPMS security keys are "DENTP SUPERVISOR"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/Encounter.read   |
      | user/Procedure.read   |
      | user/Procedure.write  |

  # ===========================================================================
  # KEYS COMBINE
  # ===========================================================================

  Scenario: Holding two keys grants the union of what each key owns, exactly
    Given a clinician whose RPMS security keys are "PRCFA TECH, SD SUPERVISOR"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/Encounter.read      |
      | user/Encounter.write     |
      | user/Location.read       |
      | user/ServiceRequest.read |

  Scenario: Overlapping keys do not duplicate a shared scope
    Given a clinician whose RPMS security keys are "DENTP PROVIDER, DENTP SUPERVISOR"
    When their session scopes are resolved
    Then the granted scopes should be exactly:
      | user/Encounter.read   |
      | user/Procedure.read   |
      | user/Procedure.write  |

  # ===========================================================================
  # SHAPE OF THE GRANT
  # ===========================================================================

  Scenario: No key in the policy can mint a patient-compartment scope
    Given a clinician holding every security key this engine models
    When their session scopes are resolved
    Then every granted scope should begin with "user/"
    And the granted scopes should not be empty

  Scenario: No key in the policy can mint a wildcard resource scope
    Given a clinician holding every security key this engine models
    When their session scopes are resolved
    Then no granted scope should name the wildcard resource type

  # ===========================================================================
  # TABLE DRIFT
  # ===========================================================================
  #
  # A key added to the RPMS registry but not to the policy is silently denied,
  # and a key in the policy with no registry entry can never be resolved from a
  # real sign-on. Both are table drift, and neither announces itself. This fails
  # the moment the two tables disagree, so adding a key forces a decision here.

  Scenario: Every RPMS security key the registry can resolve is modelled by the policy
    Then every key in the RPMS security key registry should have a scope policy entry
    And every scope policy entry should correspond to an RPMS security key

  # ===========================================================================
  # 42 CFR PART 2 — ASSERTED GAP, NOT A CONTROL (#494)
  # ===========================================================================
  #
  # The behavioural-health keys are inert on purpose. Resource-type scopes cannot
  # separate a PHQ-9 item-9 answer from a blood pressure: both arrive as
  # Observation. Granting the BH keys a resource type would look like Part 2
  # segmentation without being it, which is worse than an honest gap. These
  # scenarios pin the gap so it cannot be closed by accident — when record-level
  # segmentation lands they are expected to fail and be rewritten.

  Scenario: BGMH PROVIDER grants nothing today
    Given a clinician whose RPMS security keys are "BGMH PROVIDER"
    When their session scopes are resolved
    Then the granted scopes should be empty

  Scenario: BGMH SUPERVISOR grants nothing today
    Given a clinician whose RPMS security keys are "BGMH SUPERVISOR"
    When their session scopes are resolved
    Then the granted scopes should be empty

  Scenario: Part 2 content travels with ordinary chart access
    Given a clinician whose RPMS security keys are "OR CPRS GUI CHART"
    When their session scopes are resolved
    Then the granted scopes should include:
      | user/Observation.read |
      | user/Condition.read   |
