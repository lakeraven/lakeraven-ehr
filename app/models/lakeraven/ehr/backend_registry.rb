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

      # FHIR types each IHS capability owns (#574, #647). The supported set
      # is this map filtered by BackendRegistry.current.provides?.
      CAPABILITY_FHIR_RESOURCE_TYPES = {
        prc_referrals: %w[ServiceRequest].freeze,
        tribal_enrollment: [].freeze,
        bprm_registration: %w[Patient].freeze,
        bprm_scheduling: [].freeze,
        ihs_immunization: %w[Immunization].freeze,
        pcc_screens: [].freeze
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

        def capability_fhir_resource_types
          CAPABILITY_FHIR_RESOURCE_TYPES
        end

        def supported_fhir_resource_types
          provided = CAPABILITY_FHIR_RESOURCE_TYPES.select { |capability, _| current.provides?(capability) }
          provided.values.flatten.uniq
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
