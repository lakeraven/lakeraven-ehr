# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CurrentUserPermissionsTest < ActiveSupport::TestCase
      include HostRoleExpectations

      USER_TYPE_CASES = (
        USER_TYPES_FOR_MATRIX + [ UNKNOWN_USER_TYPE, nil ]
      ).freeze

      test "permissions and capabilities match pinned role and key matrix" do
        USER_TYPE_CASES.product(KEY_SETS_FOR_MATRIX).each do |user_type, key_set|
          user = build_user(user_type: user_type, security_keys: key_set)

          PERMISSION_SYMBOLS.each do |permission|
            assert_equal expected_can?(user_type, key_set, permission),
              user.can?(permission),
              "can?(#{permission}) for user_type=#{user_type.inspect} keys=#{key_set.inspect}"
          end

          assert_equal false, user.can?(UNKNOWN_PERMISSION),
            "unknown permission must fail closed for user_type=#{user_type.inspect} keys=#{key_set.inspect}"

          assert_equal expected_can_approve_chs?(key_set), user.can_approve_chs?,
            "can_approve_chs? for user_type=#{user_type.inspect} keys=#{key_set.inspect}"
          assert_equal expected_can_process_chs?(key_set), user.can_process_chs?,
            "can_process_chs? for user_type=#{user_type.inspect} keys=#{key_set.inspect}"
          assert_equal expected_can_manage_consults?(key_set), user.can_manage_consults?,
            "can_manage_consults? for user_type=#{user_type.inspect} keys=#{key_set.inspect}"
          assert_equal expected_case_manager?(user_type, key_set), user.case_manager?,
            "case_manager? for user_type=#{user_type.inspect} keys=#{key_set.inspect}"

          assert_equal expected_capabilities(user_type, key_set), user.capabilities,
            "capabilities for user_type=#{user_type.inspect} keys=#{key_set.inspect}"
        end
      end

      private

      def build_user(user_type:, security_keys:)
        attrs = { duz: 999, name: "TEST,USER", security_keys: security_keys }
        attrs[:user_type] = user_type unless user_type.nil?
        CurrentUser.new(attrs)
      end
    end
  end
end
