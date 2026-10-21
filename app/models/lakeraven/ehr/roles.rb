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

      class << self
        def can?(user, permission)
          permissions_for(user).include?(permission.to_sym)
        end

        def permissions_for(user)
          ROLE_PERMISSIONS[user.user_type] || ROLE_PERMISSIONS["user"]
        end

        def can_approve_chs?(user)
          has_any_key?(user, :prc_supervisor, :prc_manager)
        end

        def can_process_chs?(user)
          has_any_key?(user, :prc_tech, :prc_supervisor)
        end

        def can_manage_consults?(user)
          has_key?(user, :consult_manager)
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

        # Symbol equality on Array(security_keys). "prc_manager" does not
        # satisfy :prc_manager.
        def has_key?(user, key_symbol)
          Array(user.security_keys).include?(key_symbol)
        end

        # Round-trip the AV user_type through its class short code, then
        # elevate :prc_supervisor or :prc_manager to "case_manager".
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

        def resolve(user_class:, security_keys:)
          keys = Array(security_keys)
          if keys.include?(:prc_supervisor) || keys.include?(:prc_manager)
            "case_manager"
          else
            for_class(user_class)
          end
        end

        def for_class(user_class)
          USER_CLASS_MAP[user_class.to_s] || "user"
        end

        def can_verify_eligibility?(user)
          has_key?(user, :eligibility_verify)
        end

        def can_manage_scheduling?(user)
          has_key?(user, :scheduling_admin)
        end

        def can_access_behavioral_health?(user)
          has_any_key?(user, :bh_provider, :bh_supervisor)
        end

        def can_access_dental?(user)
          has_any_key?(user, :dental_provider, :dental_supervisor)
        end
      end
    end
  end
end
