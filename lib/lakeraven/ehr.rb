# frozen_string_literal: true

require "doorkeeper"
require "jwt"
require "lakeraven/ehr/version"
require "lakeraven/ehr/engine"

module Lakeraven
  module EHR
    class Configuration
      attr_accessor :tenant_resolver, :facility_resolver, :eligibility_adapter

      # The backend the gateways talk to, by its BackendRegistry name.
      # `rpms` is the only one registered today (#646).
      attr_accessor :backend

      # Absolute URL of the OAuth token endpoint as published in
      # .well-known/smart-configuration. When set, it is the ONLY audience
      # accepted for backend-services client assertions — the expected aud is
      # never derived from the incoming request (reverse-proxy Host mismatch
      # would otherwise break clients, and a request-derived audience lets an
      # assertion minted for one host be replayed against another).
      attr_accessor :token_endpoint_url

      # Optional provider of additional Observation model instances for a
      # patient (callable, dfn -> [Observation]). The live RPC path carries
      # vitals only, so a deployment that can source other observation types
      # (laboratory results from another backend, a synthetic fixture set)
      # plugs them in here and they are served through the same Observation
      # serializer and search filters.
      #
      # This is a TRUST BOUNDARY: the callable is deployment-supplied code that
      # injects clinical resources into a patient's chart. Everything it returns
      # is filtered to the requested patient (SupplementalClinicalResources),
      # because a mis-keyed fixture set or an adapter bug must not become a way
      # around the patient compartment the rest of the engine enforces. It
      # carries no provenance or attribution of its own -- a supplemental row is
      # indistinguishable in the response from a wire-sourced one -- so it is
      # defensible as a narrow escape hatch for known wire gaps, not as a second
      # write path into the chart.
      attr_accessor :supplemental_observations_provider

      # The same shape for AllergyIntolerance. The live RPC path (ORQQAL LIST)
      # carries only allergen, reaction and severity text; coded,
      # criticality-bearing allergies come from here. Same trust boundary.
      attr_accessor :supplemental_allergy_intolerances_provider

      # The site's limits on a signed-in browser session, after NIST SP
      # 800-63B-3 at AAL2: re-authenticate after 30 minutes of inactivity, and
      # at least every 12 hours however active the user is. A site may lower
      # them; its HIPAA automatic-logoff policy is the place to say so.
      #
      # session_idle_limit caps how long a session may sit idle. A user's RPMS
      # idle limit (their DTIME, read at sign-on) may only shorten it: DTIME is
      # a terminal setting, and PROFILE,MD's 9999 seconds would hold a chart
      # open in a browser for nearly three hours.
      attr_accessor :session_idle_limit
      # session_lifetime is how long a session lasts from sign-on, and how long
      # its SMART token is valid.
      attr_accessor :session_lifetime

      def initialize
        @session_idle_limit = 30.minutes
        @session_lifetime = 12.hours
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
