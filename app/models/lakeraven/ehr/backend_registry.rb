# frozen_string_literal: true

module Lakeraven
  module EHR
    # Which backend the gateways talk to, and what that backend can do (#646).
    #
    # Configuration names the backend (`Lakeraven::EHR.configuration.backend`,
    # `rpms` today). Gateways get their client from `BackendRegistry.current`
    # and never from rpms-rpc directly; a feature asks the current backend's
    # capability set, never the backend's name. That keeps one place where
    # a second backend (stock VistA, #642) is added: a `register` call.
    #
    # An unknown backend name fails closed: `current` raises rather than
    # falling back to RPMS.
    module BackendRegistry
      class UnknownBackendError < StandardError; end
      class UnknownCapabilityError < ArgumentError; end

      # IHS-only features: what RPMS adds on top of stock VistA (#642). A
      # backend without one reports the feature unavailable (#647).
      CAPABILITIES = %i[
        prc_referrals
        tribal_enrollment
        bprm_registration
        bprm_scheduling
        ihs_immunization
        pcc_screens
      ].freeze

      # FHIR interactions each IHS capability owns (#574, #647). Patient
      # read and search stay available with no capability; registration is
      # AG's screens, not a FHIR interaction (#542). The supported set is this map filtered
      # by BackendRegistry.current.provides?. ServiceRequest and Immunization
      # are routed index-only, so only search-type is listed; add read with
      # its show route.
      CAPABILITY_FHIR_INTERACTIONS = {
        prc_referrals: [
          %w[ServiceRequest search-type]
        ].freeze,
        tribal_enrollment: [].freeze,
        bprm_registration: [].freeze,
        bprm_scheduling: [].freeze,
        ihs_immunization: [
          %w[Immunization search-type]
        ].freeze,
        pcc_screens: [].freeze
      }.freeze

      # Stock interactions that do not belong to an IHS capability.
      BASE_FHIR_INTERACTIONS = {
        "Patient" => %w[read search-type].freeze
      }.freeze

      # A registered backend: a client source (called on every request, so a
      # client swapped in configuration is picked up) and its capabilities.
      # It carries no name, so nothing can branch on one.
      class Backend
        attr_reader :capabilities

        def initialize(client:, capabilities:)
          unknown = capabilities - CAPABILITIES
          raise UnknownCapabilityError, "unknown capabilities: #{unknown.join(', ')}" if unknown.any?

          @client_source = client
          @capabilities = capabilities.to_set.freeze
        end

        def client
          @client_source.call
        end

        def provides?(capability)
          raise UnknownCapabilityError, "unknown capability: #{capability}" unless CAPABILITIES.include?(capability)

          capabilities.include?(capability)
        end
      end

      @backends = {}

      class << self
        def register(name, client:, capabilities:)
          @backends[normalize(name)] = Backend.new(client: client, capabilities: capabilities)
        end

        def fetch(name)
          @backends.fetch(normalize(name)) do
            raise UnknownBackendError,
                  "no backend registered as #{name.inspect} (registered: #{@backends.keys.join(', ')})"
          end
        end

        def unregister(name)
          @backends.delete(normalize(name))
        end

        def current
          fetch(Lakeraven::EHR.configuration.backend)
        end

        def capability_fhir_interactions
          CAPABILITY_FHIR_INTERACTIONS
        end

        def supported_fhir_resource_types
          (BASE_FHIR_INTERACTIONS.keys + provided_fhir_pairs.map(&:first)).uniq
        end

        def supported_fhir_interactions(resource_type)
          owned = provided_fhir_pairs.filter_map { |type, name| name if type == resource_type }
          (Array(BASE_FHIR_INTERACTIONS[resource_type]) + owned).uniq
        end

        # The capability that owns this FHIR interaction, or nil when the
        # interaction is stock (or not one this server gates).
        def capability_for_fhir_interaction(resource_type, interaction)
          return if interaction.nil?

          CAPABILITY_FHIR_INTERACTIONS.each do |capability, pairs|
            return capability if pairs.any? { |type, name| type == resource_type && name == interaction }
          end
          nil
        end

        def provided_fhir_pairs
          CAPABILITY_FHIR_INTERACTIONS.flat_map do |capability, pairs|
            current.provides?(capability) ? pairs : []
          end
        end

        private

        def normalize(name)
          name.to_s.strip.downcase.to_sym
        end
      end

      register :rpms, client: -> { RpmsRpc.client }, capabilities: CAPABILITIES
    end
  end
end
