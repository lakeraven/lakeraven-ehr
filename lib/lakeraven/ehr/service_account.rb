# frozen_string_literal: true

module Lakeraven
  module EHR
    # The RPMS service account a SMART Backend Services (system/) token signs
    # on as (ADR 0011 §6, ADR 0013 decision 4, #996): one account per backend
    # client, looked up by the token's client_id (its Doorkeeper application's
    # uid). Its codes come from the host, never from the repo:
    #
    # - the host's credentials at rpms.service_accounts.<client_id>
    #   (access_code and verify_code). An entry for the client decides alone:
    #   a partial one is no account, and nothing else stands in for it.
    # - else the environment's RPMS_SERVICE_ACCESS_CODE and
    #   RPMS_SERVICE_VERIFY_CODE, which belong only to the one client
    #   RPMS_SERVICE_CLIENT_ID names (an exact match, after strip).
    #
    # There is no deployment-wide account (rpms.service_account is read by
    # nothing) and no default. Both codes or none. Read on every call, so the
    # codes are never held in a constant; never logged.
    module ServiceAccount
      ENV_KEYS = %w[RPMS_SERVICE_ACCESS_CODE RPMS_SERVICE_VERIFY_CODE].freeze
      ENV_CLIENT_ID = "RPMS_SERVICE_CLIENT_ID"

      class << self
        # [access_code, verify_code] of client_id's own account, or nil when it
        # has none. A nil or blank client_id is nobody's.
        def codes_for(client_id)
          client_id = client_id.to_s
          return nil if client_id.strip.empty?

          found, codes = from_credentials(client_id)
          found ? codes : from_env(client_id)
        end

        private

        # [whether the credentials hold an entry for the client, its codes].
        # Credentials the host cannot read (undecryptable, or mis-shaped so
        # dig raises) are no credentials: the ENV rule decides. Only the
        # error's class is logged.
        def from_credentials(client_id)
          entry = Rails.application.credentials.dig(:rpms, :service_accounts, client_id.to_sym)
          return [ false, nil ] if entry.nil?
          return [ true, nil ] unless entry.respond_to?(:dig)

          [ true, pair(entry.dig(:access_code), entry.dig(:verify_code)) ]
        rescue StandardError => e
          Rails.logger.warn("[rpms] service-account credentials unreadable: #{e.class.name}")
          [ false, nil ]
        end

        # The ENV pair, for the client RPMS_SERVICE_CLIENT_ID names and no other.
        def from_env(client_id)
          named = ENV[ENV_CLIENT_ID].to_s.strip
          return nil if named.empty? || named != client_id

          pair(*ENV_KEYS.map { |key| ENV[key] })
        end

        def pair(access_code, verify_code)
          return nil if access_code.to_s.strip.empty? || verify_code.to_s.strip.empty?

          [ access_code.to_s, verify_code.to_s ]
        end
      end
    end
  end
end
