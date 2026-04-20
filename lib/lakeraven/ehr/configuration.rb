# frozen_string_literal: true

module Lakeraven
  module EHR
    # Application-level configuration for the engine.
    #
    # Host applications configure the engine via:
    #
    #   Lakeraven::EHR.configure do |config|
    #     config.resource_owner_authenticator = ->(controller) { ... }
    #   end
    #
    # Gateway selection is driven by GatewayFactory via environment
    # variables (RPMS_INTEGRATION_MODE, RPC_PROTOCOL), not by config.
    class Configuration
      attr_accessor :resource_owner_authenticator
      attr_accessor :admin_authenticator
      attr_accessor :tenant_resolver
      attr_accessor :facility_resolver

      def initialize
        @resource_owner_authenticator = ->(_controller) {
          raise NotConfiguredError,
            "Lakeraven::EHR.configuration.resource_owner_authenticator must be set " \
            "by the host application before any SMART authorization request"
        }
        @admin_authenticator = ->(_controller) { false }

        @tenant_resolver = ->(request) {
          value = request.headers["X-Tenant-Identifier"].to_s.strip
          value.empty? ? nil : value
        }

        @facility_resolver = ->(request) {
          value = request.headers["X-Facility-Identifier"].to_s.strip
          value.empty? ? nil : value
        }
      end
    end

    class NotConfiguredError < StandardError; end

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
