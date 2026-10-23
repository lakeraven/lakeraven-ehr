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

      SECURITY_KEYS_FETCH_FAILURES = [
        [ "RpcError", -> { raise RpmsRpc::Client::RpcError.new("ORWU USERKEYS timeout") } ],
        [ "StandardError", -> { raise StandardError, "broker unavailable" } ]
      ].freeze

      AUTH_USER_TYPES_WHEN_KEYS_FETCH_FAILS = %w[provider nurse clerk user].freeze

      test "resolve_signon succeeds with base role and empty security_keys when user_security_keys raises" do
        AUTH_USER_TYPES_WHEN_KEYS_FETCH_FAILS.product(SECURITY_KEYS_FETCH_FAILURES).each do |auth_user_type, (label, raise_proc)|
          with_auth_stubs(auth_user_type: auth_user_type, user_security_keys_raise: raise_proc) do
            result = AuthenticationService.new.authenticate(
              access_code: "synthetic.access",
              verify_code: "synthetic.verify"
            )

            assert result.success?,
              "expected success when user_security_keys raises #{label} for auth_user_type=#{auth_user_type}"
            assert_equal expected_resolved_user_type(auth_user_type, []), result.value[:user_type],
              "user_type must not elevate when keys fetch fails (#{label}, auth_user_type=#{auth_user_type})"
            assert_equal [], result.value[:security_keys],
              "security_keys must be empty when fetch fails (#{label}, auth_user_type=#{auth_user_type})"
          end
        end
      end

      test "resolve_signon user_type matches pinned auth role and security key matrix" do
        AUTH_USER_TYPES.product(KEY_SETS_FOR_MATRIX).each do |auth_user_type, key_set|
          symbolic_keys = security_keys_array(key_set).grep(Symbol)
          raw_keys = raw_security_keys_for_symbolic(symbolic_keys)
          expected_keys = raw_keys.filter_map { |name| HostRoleExpectations::RPMS_KEY_STRING_BY_SYMBOL.key(name) }

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

      def with_auth_stubs(auth_user_type:, raw_keys: [], user_security_keys_raise: nil)
        RpmsRpc::Authentication.define_singleton_method(:authenticate) do |**_kwargs|
          {
            success: true,
            duz: "501",
            name: "SYNTH,USER",
            verify_needs_change: false
          }
        end

        # The class is the server's USRCLS from ORWU USERINFO, read after
        # sign-on; XUS AV CODE carries none (rpms-rpc #236).
        RpmsRpc::Authentication.define_singleton_method(:user_type) do |_duz|
          auth_user_type
        end

        RpmsRpc::Authentication.define_singleton_method(:user_info) do |_duz|
          { name: "SYNTH,USER" }
        end

        RpmsRpc::Authentication.define_singleton_method(:user_security_keys) do |_duz|
          raise user_security_keys_raise.call if user_security_keys_raise

          raw_keys
        end

        yield
      ensure
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :authenticate)
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :user_info)
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :user_type)
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :user_security_keys)
      end
    end
  end
end
