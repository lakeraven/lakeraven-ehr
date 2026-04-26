# frozen_string_literal: true

module Lakeraven
  module EHR
    module LabReconciliation
      class ReconciliationAdapterFactory
        ADAPTERS = {
          mock: -> { MockAdapter.new },
          rpms: -> { RpmsAdapter.new }
        }.freeze

        def self.build(mode = nil)
          mode ||= detect_mode
          builder = ADAPTERS[mode]
          raise ArgumentError, "Unknown lab reconciliation adapter mode: #{mode.inspect}. Available: #{ADAPTERS.keys.join(', ')}" unless builder
          builder.call
        end

        def self.detect_mode
          env_mode = ENV["LAB_RECONCILIATION_MODE"]
          return env_mode.to_sym if env_mode.present?
          Rails.env.production? ? :rpms : :mock
        end
        private_class_method :detect_mode
      end
    end
  end
end
