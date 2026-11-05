# frozen_string_literal: true

module Lakeraven
  module EHR
    # Translates a clinician's RPMS security keys into SMART scopes.
    #
    # DENY BY DEFAULT. A key that is not listed grants nothing, and a user
    # holding no listed key gets an EMPTY scope string — a session, a
    # dashboard, and no clinical data. Absence of a key must never confer
    # privilege (the defect this replaces minted `user/*.read user/*.write` for
    # every authenticated human, including a clerk with no keys at all).
    #
    # SCOPE OF THAT CLAIM — this table governs the scopes a BROWSER SESSION is
    # minted with. It is NOT the only source of privilege in the engine, and
    # saying so would be false while #496 stands: `/oauth/token` verifies no
    # JWT signature and grants caller-supplied scopes, so anyone who can reach
    # that endpoint can mint any scope they like and this table is decoration
    # to them. Closing #496 is what makes the stronger statement true; until
    # then this constrains the browser path only.
    #
    # Reading the chart comes from an OPTION: CIAV VUECENTRIC, the option RPMS
    # opens VueCentric's chart with (ADR 0010), asked of RPMS at sign-on with ORWU
    # HAS OPTION ACCESS. A CIA sign-on binds to that option's context, so anyone
    # RPMS signs on to VueCentric holds it, and RPMS still refuses any read the
    # user's own context does not allow. The engine follows RPMS here rather than
    # deciding from its own reading of the keys.
    #
    # Everything else comes from KEYS: the symbolic names in Roles::KEY_NAMES,
    # resolved from the user's KEYS at sign-on. Each entry grants only the
    # resource types that key's own RPMS workflow owns: the CHS approval key
    # grants acting on a referral, the scheduling key booking an encounter.
    #
    # 42 CFR PART 2 — READ THIS BEFORE EXTENDING THE TABLE, AND BEFORE
    # DEPLOYING ANYWHERE THAT HOLDS PART 2 CONTENT.
    #
    # Shipped position, stated plainly because it is not a Part 2 control:
    # CIAV VUECENTRIC, held by everyone RPMS signs on to VueCentric (front
    # desk and scheduler included), still grants `user/Observation.rs` and
    # `user/Condition.rs`. Part 2-bearing content still travels with ordinary
    # chart access. The behavioral health keys (`AMHZMENU`, `AMHZMGR`) grant
    # read and write of QuestionnaireResponse, the PHQ-9/GAD-7 screening
    # record, and nothing else.
    #
    # That is not segmentation. A screening's score Observation still rides
    # the chart's Observation read: the same endpoint returns that score and
    # a blood pressure, and the same `Condition` endpoint a substance-use
    # diagnosis and asthma. Resource-type scopes are the wrong granularity
    # for a record-level rule, and a table that merely LOOKED like it
    # segregated Part 2 would be a control nobody re-examines. Record-level
    # segmentation remains #494, blocking for any deployment holding Part 2
    # content.
    class SessionScopePolicy
      # Reading a chart: the read surface CIAV VUECENTRIC grants, and nothing
      # that writes.
      CHART_READ_TYPES = %w[
        Patient Practitioner Organization Location Encounter
        Observation Condition AllergyIntolerance MedicationRequest Medication
        Procedure Immunization DiagnosticReport CarePlan Provenance
      ].freeze

      # QuestionnaireResponse: the PHQ-9/GAD-7 screening record, routed by
      # ScreeningsController. The behavioral health keys grant this list, read
      # and write, because that record is their workflow; no other key or
      # option references it. The score Observation is not in this list — it
      # rides the chart option's Observation read and is not separable here.
      BEHAVIORAL_HEALTH_TYPES = %w[QuestionnaireResponse].freeze

      # Referral / purchased-care workflow.
      REFERRAL_TYPES = %w[ServiceRequest].freeze
      COVERAGE_TYPES = %w[Coverage CoverageEligibilityRequest].freeze

      # option name => { read: [types], write: [types] }. These are the options
      # sign-on asks RPMS about.
      OPTION_SCOPES = {
        "CIAV VUECENTRIC" => { read: CHART_READ_TYPES, write: [] }
      }.freeze

      # key symbol => { read: [types], write: [types] }
      KEY_SCOPES = {
        # Referred care (RCIS)
        referrals_supervisor: { read: REFERRAL_TYPES + COVERAGE_TYPES, write: REFERRAL_TYPES },
        referrals_manager: { read: REFERRAL_TYPES + COVERAGE_TYPES, write: REFERRAL_TYPES },
        referrals_user: { read: REFERRAL_TYPES, write: [] },

        # Scheduling
        scheduling_admin: { read: %w[Encounter Location], write: %w[Encounter] },
        scheduling_user: { read: %w[Encounter Location], write: %w[Encounter] },

        # Behavioural health: QuestionnaireResponse only. See the note above.
        behavioral_health_user: { read: BEHAVIORAL_HEALTH_TYPES, write: BEHAVIORAL_HEALTH_TYPES },
        behavioral_health_manager: { read: BEHAVIORAL_HEALTH_TYPES, write: BEHAVIORAL_HEALTH_TYPES }

        # Consults, eligibility and dental have no key decided yet (#578), so
        # they grant nothing; see Roles::KEY_NAMES.
      }.freeze

      class << self
        # Space-separated SMART scope string for a set of symbolic security
        # keys. Unknown keys are ignored rather than defaulted — an RPMS site
        # with a local key we do not model gets no privilege from it.
        def scope_string(security_keys:, options: [])
          scopes_for(security_keys: security_keys, options: options).join(" ")
        end

        # One SMART v2 scope per resource type: `rs` for a type the options and
        # keys let the user read, `cud` for one they let the user change, `cruds`
        # for both (SmartScope). An option the table does not list grants nothing.
        def scopes_for(security_keys:, options: [])
          granted = Array(security_keys).filter_map { |k| KEY_SCOPES[k.to_sym] } +
                    Array(options).filter_map { |name| OPTION_SCOPES[name.to_s] }

          reads = granted.flat_map { |g| g[:read] }.to_set
          writes = granted.flat_map { |g| g[:write] }.to_set

          (reads | writes).map { |type| user_scope(type, reads.include?(type), writes.include?(type)) }.sort
        end

        # Every scope this policy can ever mint. Used to declare the browser
        # SSO Doorkeeper application's scope set, so a token can never carry a
        # scope outside the table.
        def all_scopes
          scopes_for(security_keys: KEY_SCOPES.keys, options: OPTION_SCOPES.keys)
        end

        private

        def user_scope(type, read, write)
          SmartScope.build("user", type, "#{'rs' if read}#{'cud' if write}").to_s
        end
      end
    end
  end
end
