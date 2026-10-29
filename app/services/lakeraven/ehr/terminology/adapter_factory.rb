# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # Builds a terminology adapter.
      #
      # An explicit name wins. Otherwise the environment is read in order:
      # TERMINOLOGY_BACKEND, IRIS_TERMINOLOGY_URL, UMLS_API_KEY, then :local.
      # Env values, explicit arguments, and register names share one
      # normalization: to_s, strip, downcase, to_sym. A name that is not a
      # String or Symbol raises ArgumentError. build with no name (nil)
      # reads the environment instead of normalizing.
      # :local and :mock are built in. :mock raises ArgumentError in
      # production. :iris and :vsac build an adapter that raises
      # AdapterNotAvailable until a host registers one. A TERMINOLOGY_BACKEND
      # value that names nothing known does the same, so a misconfigured
      # process still boots. Any other explicit name raises ArgumentError.
      # register requires a block. build calls it and raises ArgumentError
      # unless it returns a BaseAdapter whose backend is the normalized name.
      # reset_registrations! removes host adapters and leaves the built-ins.
      class AdapterFactory
        KNOWN_BACKENDS = %i[local mock iris vsac].freeze
        PLACEHOLDER_BACKENDS = %i[iris vsac].freeze

        # No adapter is registered for this backend. Used for :iris and
        # :vsac, and for any other name TERMINOLOGY_BACKEND selects. build
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
          explicit = !backend.nil?
          name = explicit ? normalize_backend(backend) : detect_backend
          refuse_mock_in_production!(name)
          return materialize(name) if registrations.key?(name)

          known_adapter(name, explicit: explicit)
        end

        def self.register(backend, &builder)
          raise ArgumentError, "register requires a block that builds the terminology adapter" unless block_given?

          registrations[normalize_backend(backend)] = builder
        end

        def self.reset_registrations!
          @registrations = {}
        end

        def self.known_adapter(name, explicit:)
          return LocalAdapter.new if name == :local
          return MockAdapter.new if name == :mock
          return Unavailable.new(name) if !explicit || PLACEHOLDER_BACKENDS.include?(name)

          raise ArgumentError, unknown_backend_message(name)
        end
        private_class_method :known_adapter

        def self.materialize(name)
          adapter = registrations.fetch(name).call
          assert_adapter!(name, adapter)
          adapter
        end
        private_class_method :materialize

        def self.assert_adapter!(name, adapter)
          unless adapter.is_a?(BaseAdapter)
            raise ArgumentError, "Terminology backend #{name} must build a Terminology::BaseAdapter"
          end

          return if adapter.backend == name

          raise ArgumentError, "Terminology backend #{name} built an adapter for #{adapter.backend}"
        end
        private_class_method :assert_adapter!

        def self.refuse_mock_in_production!(name)
          return unless name == :mock && Rails.env.production?

          raise ArgumentError, "The mock terminology backend is refused in production"
        end
        private_class_method :refuse_mock_in_production!

        def self.detect_backend
          configured_backend || signaled_backend || :local
        end
        private_class_method :detect_backend

        def self.configured_backend
          raw = ENV["TERMINOLOGY_BACKEND"]
          return if raw.nil?

          normalize_backend(raw).presence
        end
        private_class_method :configured_backend

        # One normalization for env values, explicit arguments, and register names.
        def self.normalize_backend(name)
          unless name.is_a?(String) || name.is_a?(Symbol)
            raise ArgumentError, "Terminology backend name must be a String or Symbol"
          end

          name.to_s.strip.downcase.to_sym
        end
        private_class_method :normalize_backend

        def self.signaled_backend
          return :iris if ENV["IRIS_TERMINOLOGY_URL"].present?
          return :vsac if ENV["UMLS_API_KEY"].present?

          nil
        end
        private_class_method :signaled_backend

        def self.registrations
          @registrations ||= {}
        end
        private_class_method :registrations

        def self.unknown_backend_message(name)
          available = (KNOWN_BACKENDS + registrations.keys).uniq
          "Unknown terminology backend: #{name}. Available backends: #{available.join(', ')}"
        end
        private_class_method :unknown_backend_message
      end
    end
  end
end
