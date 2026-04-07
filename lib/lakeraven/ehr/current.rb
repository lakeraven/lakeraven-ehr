# frozen_string_literal: true

require "active_support/current_attributes"

module Lakeraven
  module EHR
    # Per-request store for tenant and facility context.
    #
    # The host application sets these at the request boundary
    # (typically from the SMART launch context or an authenticated
    # session) and engine code reads them via the fail-loud default
    # scopes described in ADR 0003.
    #
    #   Lakeraven::EHR::Current.tenant_identifier   = "tnt_..."
    #   Lakeraven::EHR::Current.facility_identifier = "fac_..."
    #
    # Background jobs that touch engine models must wrap their work
    # in `with_tenant` so the context is set even outside the request
    # cycle:
    #
    #   Lakeraven::EHR::Current.with_tenant("tnt_...") do
    #     do_some_work
    #   end
    class Current < ActiveSupport::CurrentAttributes
      attribute :tenant_identifier, :facility_identifier

      # Reset only this engine's Current class, not every
      # ActiveSupport::CurrentAttributes subclass in the process.
      # `clear_all` would wipe the host application's own Current
      # state too, which would be a hostile thing for an embedded
      # engine to do between scenarios. `instance.reset` only
      # resets the per-thread instance for this class.
      #
      # Cucumber Before hooks and test setups call this between
      # scenarios; the host app's Current is left untouched.
      def self.reset!
        instance.reset
      end

      # Run the block with tenant_identifier set to the supplied value,
      # restoring whatever was previously set when the block exits
      # (even on exception). Useful for jobs and console sessions.
      def self.with_tenant(tenant_identifier)
        previous = self.tenant_identifier
        self.tenant_identifier = tenant_identifier
        yield
      ensure
        self.tenant_identifier = previous
      end
    end

    # Raised by default scopes (and any other engine code that requires
    # tenant scoping) when Current.tenant_identifier is unset. Per
    # ADR 0003, the engine fails loudly rather than silently returning
    # an empty result set.
    class MissingTenantContextError < StandardError; end
  end
end
