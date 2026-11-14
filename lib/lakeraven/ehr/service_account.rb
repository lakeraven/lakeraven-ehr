# frozen_string_literal: true

module Lakeraven
  module EHR
    # The RPMS service account a SMART Backend Services (system/) token signs
    # on as (ADR 0011 §6, #996). Its codes come from the host, never from the
    # repo: the host's credentials (rpms.service_account.access_code and
    # verify_code) first, else its environment (RPMS_SERVICE_ACCESS_CODE and
    # RPMS_SERVICE_VERIFY_CODE). Both codes or none: a partial pair is no
    # service account, and there is no default. Read on every call, so the
    # codes are never held in a constant; never logged.
    module ServiceAccount
      ENV_KEYS = %w[RPMS_SERVICE_ACCESS_CODE RPMS_SERVICE_VERIFY_CODE].freeze

      class << self
        # [access_code, verify_code], or nil when no service account is named.
        def codes
          from_credentials || pair(*ENV_KEYS.map { |key| ENV[key] })
        end

        private

        # Credentials the host cannot read (undecryptable, or mis-shaped so
        # dig raises) are no credentials: the ENV pair decides. Only the
        # error's class is logged.
        def from_credentials
          credentials = Rails.application.credentials
          pair(credentials.dig(:rpms, :service_account, :access_code),
               credentials.dig(:rpms, :service_account, :verify_code))
        rescue StandardError => e
          Rails.logger.warn("[rpms] service-account credentials unreadable: #{e.class.name}")
          nil
        end

        def pair(access_code, verify_code)
          return nil if access_code.to_s.strip.empty? || verify_code.to_s.strip.empty?

          [ access_code.to_s, verify_code.to_s ]
        end
      end
    end
  end
end
