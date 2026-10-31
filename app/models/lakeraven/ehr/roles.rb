# frozen_string_literal: true

require "set"

module Lakeraven
  module EHR
    # Host decisions for roles and permissions.
    #
    # The RPC gem reports the security keys a user holds. This module decides
    # what a sign-on class and those keys allow. An unknown role resolves to
    # "user", whose only role permission is view_own_referrals; keys that are
    # missing or not the expected symbols add nothing. Key checks use symbol
    # equality on Array(security_keys), so a string never satisfies a symbol.
    module Roles
      # AV user-class short code => role. Codes outside this map are "user".
      USER_CLASS_MAP = {
        "1" => "admin",
        "3" => "provider",
        "4" => "nurse",
        "5" => "clerk"
      }.freeze

      REVERSE_CLASS_MAP = USER_CLASS_MAP.invert.freeze

      ROLE_PERMISSIONS = {
        "provider" => %i[view_patients view_referrals create_referrals edit_own_referrals],
        "nurse" => %i[view_patients view_referrals update_referral_status],
        "clerk" => %i[view_patients view_referrals],
        "case_manager" => %i[view_patients view_referrals approve_referrals deny_referrals manage_referrals],
        "admin" => %i[view_patients view_referrals create_referrals approve_referrals deny_referrals manage_referrals],
        "user" => %i[view_own_referrals]
      }.freeze

      # Symbolic key => the SECURITY KEY (#19.1) name RPMS reports for a user.
      # The host owns this table (ADR 0010). Every name is a key on the pinned
      # build, checked by test/models/lakeraven/ehr/roles_key_names_test.rb
      # against test/fixtures/security_keys/. The names follow the analyst's
      # profiles (rpms-ux docs/product-cycle/profiles.json) and the persona users
      # the build ships (rpms-ops SEEDPERS); the decision is #578.
      #
      # No key is decided yet for consults, eligibility verification or dental:
      # those are open questions for the analyst, and until they are answered
      # nobody holds those capabilities.
      KEY_NAMES = {
        # Order entry: every clinician who works in the chart holds one.
        orders_sign: "ORES",       # signs orders (physician, prescriber)
        orders_release: "ORELSE",  # releases orders (nurse)
        orders_enter: "OREMAS",    # enters orders for signature (clerk, medical assistant)

        # Referred care (RCIS, BMC)
        referrals_user: "BMCZMENU",
        referrals_supervisor: "BMCZSUPERVISOR",
        referrals_manager: "BMCZ MGR",

        # Registration (AG): the keys BPRM gates its registration screens on.
        registration_menu: "AGZMENU",
        registration_manager: "AGZMGR",
        registration_view_only: "AGZVIEWONLY",
        registration_view_ssn: "AGZVIEWSSN",

        # Scheduling (SD)
        scheduling_admin: "SD SUPERVISOR",
        scheduling_user: "SDZMENU",
        scheduling_supervisor: "SDZSUP",

        # Behavioral health (AMH)
        behavioral_health_user: "AMHZMENU",
        behavioral_health_manager: "AMHZMGR"
      }.freeze

      KEY_SYMBOLS = KEY_NAMES.invert.freeze

      class << self
        # The symbolic keys for the key names RPMS reported. A name the table
        # does not list is dropped: a local key the EHR does not model grants
        # nothing.
        def symbolize_keys(names)
          Array(names).filter_map { |name| KEY_SYMBOLS[name] }
        end

        def can?(user, permission)
          permissions_for(user).include?(permission.to_sym)
        end

        def permissions_for(user)
          ROLE_PERMISSIONS[user.user_type] || ROLE_PERMISSIONS["user"]
        end

        def can_approve_chs?(user)
          has_any_key?(user, :referrals_supervisor, :referrals_manager)
        end

        def can_process_chs?(user)
          has_any_key?(user, :referrals_user, :referrals_supervisor)
        end

        # No key decided yet (#578; an open question for the analyst).
        def can_manage_consults?(_user)
          false
        end

        def capabilities_for(user)
          caps = Set.new(permissions_for(user))

          caps << :approve_referrals if can_approve_chs?(user)
          caps << :deny_referrals if can_approve_chs?(user)
          caps << :process_claims if can_process_chs?(user)
          caps << :verify_eligibility if can_verify_eligibility?(user)
          caps << :manage_consults if can_manage_consults?(user)
          caps << :manage_scheduling if can_manage_scheduling?(user)
          caps << :access_behavioral_health if can_access_behavioral_health?(user)
          caps << :access_dental if can_access_dental?(user)

          caps
        end

        # Symbol equality on Array(security_keys). "referrals_manager" does not
        # satisfy :referrals_manager.
        def has_key?(user, key_symbol)
          Array(user.security_keys).include?(key_symbol)
        end

        # Round-trip the AV user_type through its class short code, then
        # elevate :referrals_supervisor or :referrals_manager to "case_manager".
        # A class the map does not know stays "user".
        def resolve_signon(user_type:, security_keys:)
          resolve(user_class: class_for(user_type), security_keys: security_keys)
        end

        private

        def has_any_key?(user, *key_symbols)
          keys = Array(user.security_keys)
          key_symbols.any? { |key| keys.include?(key) }
        end

        def class_for(role)
          REVERSE_CLASS_MAP[role.to_s]
        end

        # Call security_keys.include?(:referrals_supervisor) ||
        # security_keys.include?(:referrals_manager) directly, with no Array()
        # wrap. Nil keys raise, so sign-on fails closed rather than granting
        # a role without key data, and a Hash checks its keys.
        def resolve(user_class:, security_keys:)
          if security_keys.include?(:referrals_supervisor) || security_keys.include?(:referrals_manager)
            "case_manager"
          else
            for_class(user_class)
          end
        end

        def for_class(user_class)
          USER_CLASS_MAP[user_class.to_s] || "user"
        end

        # No key decided yet (#578; an open question for the analyst).
        def can_verify_eligibility?(_user)
          false
        end

        def can_manage_scheduling?(user)
          has_key?(user, :scheduling_admin)
        end

        def can_access_behavioral_health?(user)
          has_any_key?(user, :behavioral_health_user, :behavioral_health_manager)
        end

        # No key decided yet (#578; an open question for the analyst).
        def can_access_dental?(_user)
          false
        end
      end
    end
  end
end
