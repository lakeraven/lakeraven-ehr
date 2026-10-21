# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/authentication"

module Lakeraven
  module EHR
    class AuthenticationServiceSignonResolutionTest < ActiveSupport::TestCase
      include HostRoleExpectations

      AUTH_USER_TYPES = (
        AUTH_USER_TYPES_FOR_MATRIX + [ "synthetic_unknown_auth_role" ]
      ).freeze

      test "resolve_signon user_type matches pinned auth role and security key matrix" do
        AUTH_USER_TYPES.product(KEY_SETS_FOR_MATRIX).each do |auth_user_type, key_set|
          symbolic_keys = security_keys_array(key_set).grep(Symbol)
          raw_keys = raw_security_keys_for_symbolic(symbolic_keys)
          expected_keys = RpmsRpc::SecurityKeys.symbolize(raw_keys)

          with_auth_stubs(auth_user_type: auth_user_type, raw_keys: raw_keys) do
            result = AuthenticationService.new.authenticate(
              access_code: "synthetic.access",
              verify_code: "synthetic.verify"
            )

            assert result.success?, "expected success for auth_user_type=#{auth_user_type} keys=#{key_set.inspect}"
            expected = expected_resolved_user_type(auth_user_type, expected_keys)
            assert_equal expected, result.value[:user_type],
              "resolved user_type for auth_user_type=#{auth_user_type} keys=#{key_set.inspect}"
            assert_equal expected_keys, result.value[:security_keys]
          end
        end
      end

      private

      def with_auth_stubs(auth_user_type:, raw_keys:)
        RpmsRpc::Authentication.define_singleton_method(:authenticate) do |**_kwargs|
          {
            success: true,
            duz: "501",
            name: "SYNTH,USER",
            user_type: auth_user_type,
            verify_needs_change: false
          }
        end

        RpmsRpc::Authentication.define_singleton_method(:user_info) do |_duz|
          { name: "SYNTH,USER" }
        end

        RpmsRpc::Authentication.define_singleton_method(:user_security_keys) do |_duz|
          raw_keys
        end

        yield
      ensure
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :authenticate)
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :user_info)
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :user_security_keys)
      end
    end
  end
end
