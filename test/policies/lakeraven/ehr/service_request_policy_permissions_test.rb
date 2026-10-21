# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ServiceRequestPolicyPermissionsTest < ActiveSupport::TestCase
      ROLE_EXPECTATIONS = {
        "provider" => {
          index?: true, show?: true, create?: true, update?: true,
          approve?: false, deny?: false
        },
        "nurse" => {
          index?: true, show?: true, create?: false, update?: false,
          approve?: false, deny?: false
        },
        "clerk" => {
          index?: true, show?: true, create?: false, update?: false,
          approve?: false, deny?: false
        },
        "case_manager" => {
          index?: true, show?: true, create?: false, update?: true,
          approve?: false, deny?: false
        },
        "admin" => {
          index?: true, show?: true, create?: true, update?: true,
          approve?: false, deny?: false
        },
        "user" => {
          index?: false, show?: false, create?: false, update?: false,
          approve?: false, deny?: false
        },
        "synthetic_unknown_role" => {
          index?: false, show?: false, create?: false, update?: false,
          approve?: false, deny?: false
        }
      }.freeze

      CHS_KEY_EXPECTATIONS = {
        prc_supervisor: { approve?: true, deny?: true },
        prc_manager: { approve?: true, deny?: true },
        prc_tech: { approve?: false, deny?: false },
        string_prc_manager: { approve?: false, deny?: false }
      }.freeze

      ROLE_EXPECTATIONS.each do |role, expectations|
        test "#{role} service request policy matches pinned referral permissions" do
          policy = ServiceRequestPolicy.new(build_user(role, []), nil)

          expectations.each do |method, expected|
            assert_equal expected, policy.public_send(method),
              "#{role} #{method} expected #{expected}"
          end
        end
      end

      CHS_KEY_EXPECTATIONS.each do |label, expectations|
        test "clerk with #{label} CHS keys matches pinned approve/deny gate" do
          keys = case label
                 when :string_prc_manager then ["prc_manager"]
                 else [label]
                 end
          policy = ServiceRequestPolicy.new(build_user("clerk", keys), nil)

          expectations.each do |method, expected|
            assert_equal expected, policy.public_send(method),
              "clerk #{label} #{method} expected #{expected}"
          end
        end
      end

      private

      def build_user(role, security_keys)
        CurrentUser.new(duz: "1", name: "TEST", user_type: role, security_keys: security_keys)
      end
    end
  end
end
