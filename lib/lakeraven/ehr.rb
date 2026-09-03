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

      # Optional provider of additional Observation model instances for a
      # patient (callable, dfn -> [Observation]). The live RPC vitals path
      # (ORQQVI VITALS) only carries vital signs; a deployment that can
      # source other observation types (e.g. laboratory results from a
      # different backend, or a synthetic-sandbox fixture set) plugs them in
      # here and they are served through the same Observation serializer and
      # search filters.
      attr_accessor :supplemental_observations_provider

      def supplemental_observations_for(dfn)
        Array(supplemental_observations_provider&.call(dfn.to_s))
      end

      # Optional provider of additional AllergyIntolerance model instances
      # for a patient (callable, dfn -> [AllergyIntolerance]), mirroring
      # supplemental_observations_provider. The live RPC path (ORQQAL LIST)
      # carries only allergen/reaction/severity; a deployment that can
      # source coded, criticality-bearing allergies (e.g. a
      # synthetic-sandbox fixture set) plugs them in here and they are
      # served through the same AllergyIntolerance serializer.
      attr_accessor :supplemental_allergy_intolerances_provider

      def supplemental_allergy_intolerances_for(dfn)
        Array(supplemental_allergy_intolerances_provider&.call(dfn.to_s))
      end

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
