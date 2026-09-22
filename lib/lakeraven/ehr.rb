# frozen_string_literal: true

require "doorkeeper"
require "jwt"
require "lakeraven/ehr/version"
require "lakeraven/ehr/engine"

module Lakeraven
  module EHR
    class Configuration
      attr_accessor :tenant_resolver, :facility_resolver, :eligibility_adapter

      # Absolute URL of the OAuth token endpoint as published in
      # .well-known/smart-configuration. When set, it is the ONLY audience
      # accepted for backend-services client assertions — the expected aud is
      # never derived from the incoming request (reverse-proxy Host mismatch
      # would otherwise break clients, and a request-derived audience lets an
      # assertion minted for one host be replayed against another).
      attr_accessor :token_endpoint_url

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
