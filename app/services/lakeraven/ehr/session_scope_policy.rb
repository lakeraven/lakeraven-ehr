# frozen_string_literal: true

require "rpms_rpc/security_keys"

module Lakeraven
  module EHR
    # Translates a clinician's RPMS security keys into SMART scopes.
    #
    # DENY BY DEFAULT. The table below is the ONLY source of privilege: a key
    # that is not listed grants nothing, and a user holding no listed key gets
    # an EMPTY scope string — a session, a dashboard, and no clinical data.
    # Absence of a key must never confer privilege (the defect this replaces
    # minted `user/*.read user/*.write` for every authenticated human,
    # including a clerk with no keys at all).
    #
    # Keys are the symbolic names in RpmsRpc::SecurityKeys::REGISTRY, resolved
    # from ORWU USERKEYS at sign-on. Each entry grants only the resource types
    # that key's own RPMS workflow owns — the CPRS chart key grants reading a
    # chart, the CHS approval key grants acting on a referral, and neither
    # grants the other.
    #
    # 42 CFR PART 2 — READ THIS BEFORE EXTENDING THE TABLE.
    # Gating whole FHIR resource types on `bh_provider`/`bh_supervisor` does
    # NOT segregate Part 2 content in this engine: the same `Observation`
    # endpoint returns a PHQ-9 item-9 answer and a blood pressure, and the
    # same `Condition` endpoint returns a substance-use diagnosis and asthma.
    # Resource-type scopes are the wrong granularity for a record-level rule,
    # and a scope table that *looked* like it segregated Part 2 would be worse
    # than none — it would be a control nobody re-examines. So: BH keys grant
    # the BH-specific types this engine routes, and record-level Part 2
    # segmentation is tracked separately as real work, not simulated here (#494).
    class SessionScopePolicy
      # Reading a chart. `OR CPRS GUI CHART` is literally the RPMS option that
      # says "this user may open a patient chart", so it maps to the chart's
      # read surface — and to nothing that writes.
      CHART_READ_TYPES = %w[
        Patient Practitioner Organization Location Encounter
        Observation Condition AllergyIntolerance MedicationRequest Medication
        Procedure Immunization DiagnosticReport CarePlan Consent Provenance
      ].freeze

      # Resource types this engine serves that are behavioural-health specific.
      # Empty today: the BH content it can surface arrives through the general
      # clinical types above and is not separable at this granularity. Kept as
      # a named, asserted-on constant so the gate exists the moment a
      # BH-specific type is routed, rather than being remembered.
      BEHAVIORAL_HEALTH_TYPES = [].freeze

      # Referral / purchased-care workflow.
      REFERRAL_TYPES = %w[ServiceRequest].freeze
      COVERAGE_TYPES = %w[Coverage CoverageEligibilityRequest].freeze

      # key symbol => { read: [types], write: [types] }
      KEY_SCOPES = {
        # Clinical
        cprs_gui_chart: { read: CHART_READ_TYPES, write: [] },

        # PRC / CHS — purchased & referred care
        prc_supervisor: { read: REFERRAL_TYPES + COVERAGE_TYPES, write: REFERRAL_TYPES },
        prc_manager: { read: REFERRAL_TYPES + COVERAGE_TYPES, write: REFERRAL_TYPES },
        prc_tech: { read: REFERRAL_TYPES, write: [] },
        chs_approve: { read: REFERRAL_TYPES, write: REFERRAL_TYPES },
        chs_clerk: { read: REFERRAL_TYPES, write: [] },

        # Consults
        consult_manager: { read: REFERRAL_TYPES, write: REFERRAL_TYPES },

        # Eligibility
        eligibility_verify: { read: COVERAGE_TYPES, write: COVERAGE_TYPES },

        # Scheduling
        scheduling_admin: { read: %w[Encounter Location], write: %w[Encounter] },

        # Behavioural health (42 CFR Part 2) — see the note above.
        bh_provider: { read: BEHAVIORAL_HEALTH_TYPES, write: BEHAVIORAL_HEALTH_TYPES },
        bh_supervisor: { read: BEHAVIORAL_HEALTH_TYPES, write: BEHAVIORAL_HEALTH_TYPES },

        # Dental
        dental_provider: { read: %w[Procedure Condition Encounter], write: %w[Procedure Condition] },
        dental_supervisor: { read: %w[Procedure Condition Encounter], write: %w[Procedure Condition] }
      }.freeze

      class << self
        # Space-separated SMART scope string for a set of symbolic security
        # keys. Unknown keys are ignored rather than defaulted — an RPMS site
        # with a local key we do not model gets no privilege from it.
        def scope_string(security_keys:)
          scopes_for(security_keys: security_keys).join(" ")
        end

        def scopes_for(security_keys:)
          granted = Array(security_keys).filter_map { |k| KEY_SCOPES[k.to_sym] }

          reads = granted.flat_map { |g| g[:read] }.uniq.map { |t| "user/#{t}.read" }
          writes = granted.flat_map { |g| g[:write] }.uniq.map { |t| "user/#{t}.write" }

          (reads + writes).sort
        end

        # Every scope this policy can ever mint. Used to declare the browser
        # SSO Doorkeeper application's scope set, so a token can never carry a
        # scope outside the table.
        def all_scopes
          KEY_SCOPES.keys.then { |keys| scopes_for(security_keys: keys) }
        end
      end
    end
  end
end
