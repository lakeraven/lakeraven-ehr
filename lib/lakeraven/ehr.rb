# frozen_string_literal: true

require "doorkeeper"
require "lakeraven/ehr/version"
require "lakeraven/ehr/engine"

module Lakeraven
  module EHR
    class Configuration
      # HIPAA §164.316(b)(2) — six years is the floor, not a preference. A
      # host may keep audit records LONGER (a state rule, a tribal records
      # policy); shorter is a violation and AuditRetention refuses it.
      MINIMUM_AUDIT_RETENTION = 6.years

      attr_accessor :tenant_resolver, :facility_resolver, :eligibility_adapter,
                    :audit_retention_period, :audit_digest_key,
                    :audit_review_security_keys

      def initialize
        @tenant_resolver = ->(request) {
          value = request.headers["X-Tenant-Identifier"].to_s.strip
          value.empty? ? nil : value
        }
        @facility_resolver = ->(request) {
          value = request.headers["X-Facility-Identifier"].to_s.strip
          value.empty? ? nil : value
        }
        @eligibility_adapter = MockEligibilityAdapter.new
        @audit_retention_period = MINIMUM_AUDIT_RETENTION
        # Outside the database on purpose: a digest whose key is stored next
        # to the rows it seals can be recomputed by anyone who altered them.
        @audit_digest_key = ENV["LAKERAVEN_EHR_AUDIT_DIGEST_KEY"].presence
        # Which RPMS security keys may READ the audit log. Empty by default,
        # and an empty list REFUSES everyone: the key names differ per site
        # and inventing one here would open the log to whatever that name
        # happens to mean at a real deployment.
        @audit_review_security_keys = []
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      def reset_configuration!
        @configuration = Configuration.new
      end
    end
  end
end
