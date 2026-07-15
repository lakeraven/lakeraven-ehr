# frozen_string_literal: true

require "doorkeeper"
require "lakeraven/ehr/version"
require "lakeraven/ehr/engine"
require "lakeraven/ehr/backend"

module Lakeraven
  module EHR
    class Configuration
      attr_accessor :tenant_resolver, :facility_resolver, :eligibility_adapter,
                    :backend, :client

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
        @backend = :rpms
        @client = nil
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
        apply_client_to_backend!
        Backend.reset!
      end

      def reset_configuration!
        @configuration = Configuration.new
        Backend.reset!
      end

      private

      def apply_client_to_backend!
        client = configuration.client
        return unless client

        # The underlying RPC client is shared via vista-rpc regardless of
        # whether the configured backend is RPMS or stock VistA.
        VistaRpc.configure { |c| c.client = client }
      end
    end
  end
end
