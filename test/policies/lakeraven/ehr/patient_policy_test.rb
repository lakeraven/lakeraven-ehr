# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientPolicyTest < ActiveSupport::TestCase
      ROLE_EXPECTATIONS = {
        "provider" => { index?: true, show?: true },
        "nurse" => { index?: true, show?: true },
        "clerk" => { index?: true, show?: true },
        "case_manager" => { index?: true, show?: true },
        "admin" => { index?: true, show?: true },
        "user" => { index?: false, show?: false },
        "synthetic_unknown_role" => { index?: false, show?: false }
      }.freeze

      ROLE_EXPECTATIONS.each do |role, expectations|
        test "#{role} patient policy matches pinned view_patients gate" do
          policy = PatientPolicy.new(build_user(role), nil)

          expectations.each do |method, expected|
            assert_equal expected, policy.public_send(method),
              "#{role} #{method} expected #{expected}"
          end
        end
      end

      private

      def build_user(role)
        CurrentUser.new(duz: "1", name: "TEST", user_type: role, security_keys: [])
      end
    end
  end
end
