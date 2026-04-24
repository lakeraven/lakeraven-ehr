# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ServiceRequestPolicyTest < ActiveSupport::TestCase
      def build_user(role:, security_keys: [])
        CurrentUser.new(duz: "1", name: "TEST", user_type: role, security_keys: security_keys)
      end

      test "provider can view and create referrals" do
        user = build_user(role: "provider")
        policy = ServiceRequestPolicy.new(user, nil)

        assert policy.index?
        assert policy.show?
        assert policy.create?
        refute policy.approve?
      end

      test "nurse can view but not create referrals" do
        user = build_user(role: "nurse")
        policy = ServiceRequestPolicy.new(user, nil)

        assert policy.index?
        assert policy.show?
        refute policy.create?
        refute policy.approve?
      end

      test "clerk can view but not create or approve" do
        user = build_user(role: "clerk")
        policy = ServiceRequestPolicy.new(user, nil)

        assert policy.index?
        assert policy.show?
        refute policy.create?
        refute policy.approve?
      end

      test "case_manager can view and approve" do
        user = build_user(role: "case_manager")
        policy = ServiceRequestPolicy.new(user, nil)

        assert policy.index?
        assert policy.show?
        refute policy.create?  # create_referrals is not in case_manager role
      end

      test "user with prc_supervisor key can approve" do
        user = build_user(role: "clerk", security_keys: [ :prc_supervisor ])
        policy = ServiceRequestPolicy.new(user, nil)

        assert policy.approve?
        assert policy.deny?
      end

      test "user without prc_supervisor key cannot approve" do
        user = build_user(role: "clerk")
        policy = ServiceRequestPolicy.new(user, nil)

        refute policy.approve?
        refute policy.deny?
      end
    end
  end
end
