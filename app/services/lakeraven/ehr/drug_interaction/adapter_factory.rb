# frozen_string_literal: true

module Lakeraven
  module EHR
    module DrugInteraction
      # Selects a drug-interaction adapter.
      #
      # Hosts register a backend inside config.to_prepare. Development reloads
      # this class and drops registrations; to_prepare runs again afterward:
      #
      #   config.to_prepare do
      #     Lakeraven::EHR::DrugInteraction::AdapterFactory.register(:rpms) do
      #       # a DrugInteraction::BaseAdapter whose #backend is :rpms
      #     end
      #   end
      #
      # build with no argument reads DRUG_INTERACTION_BACKEND, stripped and
      # downcased, and uses :local when that variable is blank. An explicit
      # String or Symbol is normalized the same way. Anything else raises
      # ArgumentError.
      #
      # :local and :mock are built in. reset_registrations! removes host
      # registrations and leaves those two in place. :mock is refused in
      # production: an explicit build raises ArgumentError, and
      # DRUG_INTERACTION_BACKEND=mock returns an adapter whose checks raise
      # AdapterNotAvailable.
      #
      # :rpms, :iris, :fass, and :fdb are documented names. Until a host
      # registers one, build returns an adapter that raises AdapterNotAvailable
      # and names that backend. An unknown DRUG_INTERACTION_BACKEND value does
      # the same. An explicit unknown name raises ArgumentError and lists the
      # documented backends. Backend names are never constantized.
      class AdapterFactory
        DOCUMENTED_BACKENDS = %i[local mock rpms iris fass fdb].freeze

        BUILTIN_BUILDERS = {
          local: -> { LocalAdapter.new },
          mock: -> { MockAdapter.new }
        }.freeze

        class << self
          def build(backend = nil)
            explicit = !backend.nil?
            name = explicit ? normalize_backend(backend) : configured_backend
            return production_mock_adapter(explicit) if name == :mock && Rails.env.production?

            materialize(name, explicit)
          end

          def register(name, &block)
            raise ArgumentError, "register requires a block" unless block

            registrations[normalize_backend(name)] = block
          end

          def reset_registrations!
            @registrations = {}
          end

          private

          def configured_backend
            raw = ENV["DRUG_INTERACTION_BACKEND"].to_s.strip.downcase
            return :local if raw.empty?

            raw.to_sym
          end

          def normalize_backend(backend)
            unless backend.is_a?(String) || backend.is_a?(Symbol)
              raise ArgumentError, "drug interaction backend must be a String or Symbol (got #{backend.class})"
            end

            backend.to_s.strip.downcase.to_sym
          end

          def production_mock_adapter(explicit)
            if explicit
              raise ArgumentError, "mock drug interaction backend is not allowed in production"
            end

            UnavailableAdapter.new(:mock)
          end

          def materialize(name, explicit)
            builder = registrations[name] || BUILTIN_BUILDERS[name]
            return instantiate(builder, name) if builder
            return UnavailableAdapter.new(name) if !explicit || DOCUMENTED_BACKENDS.include?(name)

            raise ArgumentError, unknown_backend_message(name)
          end

          def instantiate(builder, name)
            adapter = builder.call
            validate_adapter!(adapter, name)
            adapter
          end

          def validate_adapter!(adapter, name)
            unless adapter.is_a?(BaseAdapter)
              raise ArgumentError, "drug interaction backend #{name} must return a BaseAdapter (got #{adapter.class})"
            end

            reported = reported_backend(adapter)
            return if reported == name

            raise ArgumentError, "drug interaction backend #{name} reported backend #{reported.inspect}"
          end

          # A bare BaseAdapter raises NotImplementedError from #backend.
          # build reports that as ArgumentError so callers can tell a bad
          # registration from an adapter that has not been written yet.
          def reported_backend(adapter)
            adapter.backend
          rescue NotImplementedError
            nil
          end

          def unknown_backend_message(name)
            available = DOCUMENTED_BACKENDS.join(", ")
            "unknown drug interaction backend: #{name}. Available: #{available}"
          end

          def registrations
            @registrations ||= {}
          end
        end
      end
    end
  end
end
