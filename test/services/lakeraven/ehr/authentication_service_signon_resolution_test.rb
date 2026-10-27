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

      AUTH_USER_TYPES_WHEN_KEYS_FETCH_FAILS = %w[provider nurse clerk user].freeze

      # held_keys answers nil when it could not ask (a refusal, no reply, a
      # reply that does not answer every name). A session must not be built on
      # keys nobody read (#578): the sign-on is refused as unavailable.
      test "a key read that could not be made refuses the sign-on, at every user class" do
        AUTH_USER_TYPES_WHEN_KEYS_FETCH_FAILS.each do |auth_user_type|
          with_auth_stubs(auth_user_type: auth_user_type, keys_unreadable: true) do
            error = assert_raises(SecurityKeyGateway::Unreadable, "auth_user_type=#{auth_user_type}") do
              AuthenticationService.new.authenticate(access_code: "synthetic.access", verify_code: "synthetic.verify")
            end
            assert_kind_of RpmsRpc::Client::RpcError, error, "the sessions controller answers RpcError as unavailable"
          end
        end
      end

      test "sign-on asks RPMS for exactly the keys the policy table names" do
        with_auth_stubs(auth_user_type: "provider") do |asked|
          AuthenticationService.new.authenticate(access_code: "synthetic.access", verify_code: "synthetic.verify")

          assert_equal [ Roles::KEY_NAMES.values ], asked
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
            assert_equal expected_keys.sort, result.value[:security_keys].sort
          end
        end
      end

      private

      def with_auth_stubs(auth_user_type:, raw_keys: [], keys_unreadable: false)
        asked = []
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

        # CIAVCXUS HASKEYS: the names asked that the user holds, in the order
        # asked, or nil when it could not ask.
        RpmsRpc::Authentication.define_singleton_method(:held_keys) do |names|
          asked << names
          keys_unreadable ? nil : names.select { |name| raw_keys.include?(name) }
        end

        yield asked
      ensure
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :authenticate)
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :user_info)
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :user_type)
        RpmsRpc::Authentication.singleton_class.send(:remove_method, :held_keys)
      end
    end
  end
end
