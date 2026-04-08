# frozen_string_literal: true

module Lakeraven
  module EHR
    # Application-level configuration for the engine.
    #
    # Host applications configure the engine via:
    #
    #   Lakeraven::EHR.configure do |config|
    #     config.adapter = MyAdapter.new
    #   end
    #
    # The adapter is the only required setting at boot.
    class Configuration
      attr_accessor :adapter
      attr_accessor :resource_owner_authenticator
      attr_accessor :admin_authenticator
      attr_accessor :tenant_resolver
      attr_accessor :facility_resolver

      def initialize
        @adapter = nil
        # Default resource owner authenticator: fail loud. The host
        # application MUST override this with a lambda that returns
        # the authenticated user (or redirects). Doorkeeper invokes
        # this on every authorization request, so leaving it
        # unconfigured surfaces immediately.
        @resource_owner_authenticator = ->(_controller) {
          raise NotConfiguredError,
            "Lakeraven::EHR.configuration.resource_owner_authenticator must be set " \
            "by the host application before any SMART authorization request"
        }
        # Default admin authenticator: deny everything. The host
        # overrides if it wants to expose the Doorkeeper admin UI.
        @admin_authenticator = ->(_controller) { false }

        # Default tenant resolver: read X-Tenant-Identifier header.
        # Host SaaS apps override this with subdomain extraction or
        # any other policy. Receives the request object and returns
        # an opaque tenant identifier (or nil).
        @tenant_resolver = ->(request) {
          value = request.headers["X-Tenant-Identifier"].to_s.strip
          value.empty? ? nil : value
        }

        # Default facility resolver: read X-Facility-Identifier header.
        # May return nil; facility scoping is optional.
        @facility_resolver = ->(request) {
          value = request.headers["X-Facility-Identifier"].to_s.strip
          value.empty? ? nil : value
        }
      end
    end

    # Raised when engine code touches the adapter before the host has
    # configured one. Surfaces immediately, before any feature runs.
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

      # Convenience accessor — engine code reads through here rather
      # than touching configuration directly.
      def adapter
        configuration.adapter || raise(
          NotConfiguredError,
          "Lakeraven::EHR.adapter is not configured. " \
          "Set one via Lakeraven::EHR.configure { |c| c.adapter = ... } " \
          "before using the engine."
        )
      end
    end
  end
end
