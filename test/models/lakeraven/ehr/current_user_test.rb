# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CurrentUserTest < ActiveSupport::TestCase
      # =============================================================================
      # BASIC INITIALIZATION
      # =============================================================================

      test "initializes with auth result hash" do
        user = build_user(user_type: "provider", duz: 123, name: "Test Provider")

        assert_equal 123, user.duz
        assert_equal "Test Provider", user.name
        assert_equal "provider", user.user_type
      end

      test "defaults to user type when not specified" do
        user = CurrentUser.new(duz: 123, name: "Test")
        assert_equal "user", user.user_type
      end

      test "string-keyed attrs behave like symbol-keyed attrs" do
        symbol_attrs = {
          user_type: "provider",
          security_keys: [ :referrals_supervisor ],
          duz: "501",
          name: "TEST,USER"
        }
        string_attrs = {
          "user_type" => "provider",
          "security_keys" => [ :referrals_supervisor ],
          "duz" => "501",
          "name" => "TEST,USER"
        }

        from_symbols = CurrentUser.new(symbol_attrs)
        from_strings = CurrentUser.new(string_attrs)

        assert_equal from_symbols.user_type, from_strings.user_type
        assert_equal from_symbols.can?(:create_referrals), from_strings.can?(:create_referrals)
        assert_equal from_symbols.can_approve_chs?, from_strings.can_approve_chs?
        assert_equal from_symbols.capabilities, from_strings.capabilities
      end

      # =============================================================================
      # ROLE CHECKS
      # =============================================================================

      test "provider? returns true for provider user type" do
        user = build_user(user_type: "provider")
        assert user.provider?
      end

      test "nurse? returns true for nurse user type" do
        user = build_user(user_type: "nurse")
        assert user.nurse?
      end

      test "clerk? returns true for clerk user type" do
        user = build_user(user_type: "clerk")
        assert user.clerk?
      end

      test "case_manager? returns true for case_manager user type" do
        user = build_user(user_type: "case_manager")
        assert user.case_manager?
      end

      test "case_manager? returns true for user with referrals_manager key" do
        user = build_user(user_type: "clerk", security_keys: [ :referrals_manager ])
        assert user.case_manager?
      end

      # =============================================================================
      # ROLE PERMISSIONS (can? method)
      # =============================================================================

      test "provider can view_patients" do
        user = build_user(user_type: "provider")
        assert user.can?(:view_patients)
      end

      test "provider can create_referrals" do
        user = build_user(user_type: "provider")
        assert user.can?(:create_referrals)
      end

      test "nurse can view_referrals" do
        user = build_user(user_type: "nurse")
        assert user.can?(:view_referrals)
      end

      test "clerk cannot create_referrals" do
        user = build_user(user_type: "clerk")
        refute user.can?(:create_referrals)
      end

      test "case_manager can approve_referrals" do
        user = build_user(user_type: "case_manager")
        assert user.can?(:approve_referrals)
      end

      test "user can only view_own_referrals" do
        user = build_user(user_type: "user")
        assert user.can?(:view_own_referrals)
        refute user.can?(:view_patients)
      end

      # =============================================================================
      # CHS-SPECIFIC PERMISSIONS
      # =============================================================================

      test "can_approve_chs? requires referrals_supervisor or referrals_manager key" do
        user_with_supervisor = build_user(user_type: "clerk", security_keys: [ :referrals_supervisor ])
        user_with_manager = build_user(user_type: "clerk", security_keys: [ :referrals_manager ])
        user_without_key = build_user(user_type: "case_manager", security_keys: [])

        assert user_with_supervisor.can_approve_chs?
        assert user_with_manager.can_approve_chs?
        refute user_without_key.can_approve_chs?
      end

      test "can_process_chs? requires referrals_user or referrals_supervisor key" do
        user_with_tech = build_user(user_type: "clerk", security_keys: [ :referrals_user ])
        user_with_supervisor = build_user(user_type: "clerk", security_keys: [ :referrals_supervisor ])
        user_without_key = build_user(user_type: "clerk", security_keys: [])

        assert user_with_tech.can_process_chs?
        assert user_with_supervisor.can_process_chs?
        refute user_without_key.can_process_chs?
      end

      # The analyst has not named a key for consults, eligibility verification
      # or dental yet (#578), so no key the EHR knows grants them.
      test "consults, eligibility and dental are granted by no key until one is decided" do
        user = build_user(user_type: "provider", security_keys: Lakeraven::EHR::Roles::KEY_NAMES.keys)

        refute user.can_manage_consults?
        refute_includes user.capabilities, :manage_consults
        refute_includes user.capabilities, :verify_eligibility
        refute_includes user.capabilities, :access_dental
      end
      # =============================================================================
      # CAPABILITIES (aggregated permissions)
      # =============================================================================

      test "capabilities includes role permissions" do
        user = build_user(user_type: "provider")
        caps = user.capabilities

        assert caps.include?(:view_patients)
        assert caps.include?(:create_referrals)
        assert caps.include?(:view_referrals)
      end

      test "capabilities includes key-derived approve_referrals permission" do
        user = build_user(user_type: "clerk", security_keys: [ :referrals_supervisor ])
        caps = user.capabilities

        assert caps.include?(:approve_referrals)
        assert caps.include?(:deny_referrals)
      end

      test "capabilities includes key-derived process_claims permission" do
        user = build_user(user_type: "clerk", security_keys: [ :referrals_user ])
        caps = user.capabilities

        assert caps.include?(:process_claims)
      end

      test "capabilities includes manage_scheduling for scheduling admin" do
        user = build_user(user_type: "clerk", security_keys: [ :scheduling_admin ])
        caps = user.capabilities

        assert caps.include?(:manage_scheduling)
      end

      test "capabilities includes access_behavioral_health for BH providers" do
        user = build_user(user_type: "provider", security_keys: [ :behavioral_health_user ])
        caps = user.capabilities

        assert caps.include?(:access_behavioral_health)
      end


      private

      def build_user(user_type:, duz: 999, name: "TEST,USER", security_keys: [])
        CurrentUser.new(duz: duz, name: name, user_type: user_type, security_keys: security_keys)
      end
    end
  end
end
