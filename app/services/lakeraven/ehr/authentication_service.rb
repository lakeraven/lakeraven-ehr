# frozen_string_literal: true

require "rpms_rpc/api/authentication"
require "rpms_rpc/security_keys"
require "rpms_rpc/user_roles"

module Lakeraven
  module EHR
    class AuthenticationService
      Result = Data.define(:success?, :value, :error)

      def authenticate(access_code:, verify_code:)
        return failure("Password required") if verify_code.to_s.empty?

        auth = RpmsRpc::Authentication.authenticate(access_code: access_code, verify_code: verify_code)
        return failure(auth[:error] || "Invalid access/verify code") unless auth[:success]

        duz_s = auth[:duz].to_s
        user_info = RpmsRpc::Authentication.user_info(duz_s)
        raw_keys = fetch_raw_security_keys(duz_s)
        symbolic_keys = RpmsRpc::SecurityKeys.symbolize(raw_keys)

        # The Authentication API resolves user_type from the AV CODE response's
        # user_class field. Feed that back into UserRoles.resolve so its
        # security-key elevation rules (e.g., PRCFA SUPERVISOR → case_manager)
        # still apply on top.
        user_info_for_resolve = (user_info || {}).merge(
          is_provider: auth[:user_type] == "provider",
          user_class: RpmsRpc::UserRoles.class_for(auth[:user_type])
        )

        Result.new(
          success?: true,
          error: nil,
          value: {
            duz: duz_s,
            name: user_info&.dig(:name) || auth[:name].to_s,
            user_type: RpmsRpc::UserRoles.resolve(user_info: user_info_for_resolve, security_keys: symbolic_keys),
            security_keys: symbolic_keys
          }
        )
      end

      private

      def failure(message)
        Result.new(success?: false, value: nil, error: message)
      end

      def fetch_raw_security_keys(duz)
        RpmsRpc::Authentication.user_security_keys(duz)
      rescue => e
        Rails.logger.error("Failed to load security keys for DUZ #{duz}: #{e.message}") if defined?(Rails)
        []
      end
    end
  end
end
