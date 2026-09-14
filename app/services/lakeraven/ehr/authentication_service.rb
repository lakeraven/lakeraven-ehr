# frozen_string_literal: true

require "rpms_rpc/api/authentication"
require "rpms_rpc/security_keys"
require "rpms_rpc/user_roles"

module Lakeraven
  module EHR
    class AuthenticationService
      Result = Data.define(:success?, :value, :error)

      # Sign on and resolve everything the session is built from.
      #
      # This spans SEVERAL calls into the gem — authenticate, then the user
      # lookup, then ORWU USERKEYS — and they all read from one process-global
      # broker session. Locking each one individually is not enough: a second
      # sign-on landing between them returns THIS caller the other clinician's
      # name and security keys, which is to say their scopes. The whole
      # sequence is therefore one unit (rpms-rpc#235).
      #
      # Guarded because the lock is newer than this call site; against a gem
      # without it the sequence simply runs unsynchronized, as it did before.
      # NOTE: even with it, one global client still holds one broker identity —
      # this narrows the window, it does not close it (rpms-rpc#234).
      def authenticate(access_code:, verify_code:)
        return failure("Password required") if verify_code.to_s.empty?

        with_broker_wire_lock { resolve_signon(access_code, verify_code) }
      end

      private

      def with_broker_wire_lock(&block)
        return yield unless RpmsRpc.respond_to?(:synchronize_wire)

        RpmsRpc.synchronize_wire(&block)
      end

      def resolve_signon(access_code, verify_code)
        auth = RpmsRpc::Authentication.authenticate(access_code: access_code, verify_code: verify_code)
        return failure(auth[:error] || "Invalid access/verify code") unless auth[:success]

        duz_s = auth[:duz].to_s
        user_info = RpmsRpc::Authentication.user_info(duz_s)
        raw_keys = fetch_raw_security_keys(duz_s)
        symbolic_keys = RpmsRpc::SecurityKeys.symbolize(raw_keys)

        # Authentication already resolved user_type from the AV CODE response's
        # user_class. Round-trip back to the user_class short code so
        # UserRoles.resolve's security-key elevation rules (e.g.,
        # PRCFA SUPERVISOR → case_manager) still apply on top.
        user_class = RpmsRpc::UserRoles.class_for(auth[:user_type])

        Result.new(
          success?: true,
          error: nil,
          value: {
            duz: duz_s,
            name: user_info&.dig(:name) || auth[:name].to_s,
            user_type: RpmsRpc::UserRoles.resolve(user_class: user_class, security_keys: symbolic_keys),
            security_keys: symbolic_keys,
            # RPMS said this verify code must be changed (admin reset, or aged
            # out). Dropping the flag granted a full session on a temporary
            # credential where CPRS would force the change first; the caller
            # decides, but it can only decide if it is told.
            verify_needs_change: auth[:verify_needs_change] == true
          }
        )
      end

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
