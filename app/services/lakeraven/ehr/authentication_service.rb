# frozen_string_literal: true

module Lakeraven
  module EHR
    class AuthenticationService
      Result = Data.define(:success?, :value, :error)

      def authenticate(access_code:, verify_code:)
        return failure("Password required") if verify_code.to_s.empty?

        parsed = RpmsRpc::DataMapper[:av_code].fetch_lines("#{access_code};#{verify_code}")
        return failure("Invalid access/verify code") if parsed.nil? || parsed[:duz].nil? || parsed[:duz] == 0

        duz_s = parsed[:duz].to_s
        user_info = RpmsRpc::DataMapper[:user_info].fetch_one(duz_s)
        raw_keys = fetch_raw_security_keys(duz_s)
        symbolic_keys = RpmsRpc::SecurityKeys.symbolize(raw_keys)

        Result.new(
          success?: true,
          error: nil,
          value: {
            duz: duz_s,
            name: user_info&.dig(:name) || parsed[:greeting].to_s,
            user_type: RpmsRpc::UserRoles.resolve(user_info: user_info, security_keys: symbolic_keys),
            security_keys: symbolic_keys
          }
        )
      end

      private

      def failure(message)
        Result.new(success?: false, value: nil, error: message)
      end

      def fetch_raw_security_keys(duz)
        RpmsRpc::DataMapper[:user_keys].fetch_many(duz).map { |r| r[:key_name] }.compact
      rescue => e
        Rails.logger.error("Failed to load security keys for DUZ #{duz}: #{e.message}") if defined?(Rails)
        []
      end
    end
  end
end
