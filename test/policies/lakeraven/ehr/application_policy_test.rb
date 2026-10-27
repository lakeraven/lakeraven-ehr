# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ApplicationPolicyTest < ActiveSupport::TestCase
      ROLE_EXPECTATIONS = {
        "provider" => { index?: true, show?: true, create?: false, update?: false, destroy?: false },
        "nurse" => { index?: true, show?: true, create?: false, update?: false, destroy?: false },
        "clerk" => { index?: true, show?: true, create?: false, update?: false, destroy?: false },
        "case_manager" => { index?: true, show?: true, create?: false, update?: false, destroy?: false },
        "admin" => { index?: true, show?: true, create?: false, update?: false, destroy?: false },
        "user" => { index?: false, show?: false, create?: false, update?: false, destroy?: false },
        "synthetic_unknown_role" => { index?: false, show?: false, create?: false, update?: false, destroy?: false }
      }.freeze

      ROLE_EXPECTATIONS.each do |role, expectations|
        test "#{role} application policy matches pinned view_patients gate" do
          policy = ApplicationPolicy.new(build_user(role), nil)

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
