# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # Builds a terminology adapter.
      #
      # An explicit name wins. Otherwise the environment is read in order:
      # TERMINOLOGY_BACKEND, IRIS_TERMINOLOGY_URL, UMLS_API_KEY, then :local.
      # :local and :mock are built in. :iris and :vsac build an adapter that
      # raises AdapterNotAvailable until a host registers one. Any other
      # name raises ArgumentError. register adds a host adapter;
      # reset_registrations! removes those and leaves the built-ins.
      class AdapterFactory
        KNOWN_BACKENDS = %i[local mock iris vsac].freeze

        # Recognized, but no production adapter ships for these. build
        # still returns an object so detection can succeed; calling an
        # operation names the backend and raises AdapterNotAvailable.
        class Unavailable < BaseAdapter
          def initialize(backend)
            @backend = backend
          end

          attr_reader :backend

          def expand_valueset(_valueset_id)
            unavailable!
          end

          def get_valueset(_valueset_id)
            unavailable!
          end

          def list_valuesets
            unavailable!
          end

          def search(_query)
            unavailable!
          end

          def lookup_code(_system, _code)
            unavailable!
          end

          def validate_code(_system, _code, valueset_id:)
            unavailable!
          end

          private

          def unavailable!
            raise AdapterNotAvailable, "No adapter is registered for the #{@backend} terminology backend"
          end
        end

        def self.build(backend = nil)
          name = (backend || detect_backend).to_sym
          return registrations.fetch(name).call if registrations.key?(name)
          return LocalAdapter.new if name == :local
          return MockAdapter.new if name == :mock
          return Unavailable.new(name) if name == :iris || name == :vsac

          raise ArgumentError, unknown_backend_message(name)
        end

        def self.register(backend, &builder)
          registrations[backend.to_sym] = builder
        end

        def self.reset_registrations!
          @registrations = {}
        end

        def self.detect_backend
          configured = ENV["TERMINOLOGY_BACKEND"].presence
          return configured.to_sym if configured
          return :iris if ENV["IRIS_TERMINOLOGY_URL"].present?
          return :vsac if ENV["UMLS_API_KEY"].present?

          :local
        end

        def self.registrations
          @registrations ||= {}
        end

        def self.unknown_backend_message(name)
          available = (KNOWN_BACKENDS + registrations.keys).uniq
          "Unknown terminology backend: #{name}. Available backends: #{available.join(', ')}"
        end

        private_class_method :detect_backend, :registrations, :unknown_backend_message
      end
    end
  end
end
