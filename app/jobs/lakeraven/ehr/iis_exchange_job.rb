# frozen_string_literal: true

module Lakeraven
  module EHR
    # State Immunization Information System (IIS) exchange job.
    # Dispatches to StateIisExchangeService operations.
    class IisExchangeJob < ApplicationJob
      queue_as :integrations

      OPERATIONS_REQUIRING_DFN = %i[send query sync].freeze
      VALID_OPERATIONS = %i[send query process_responses sync].freeze

      def perform(operation:, dfn: nil)
        operation = operation.to_sym
        validate_operation!(operation)
        validate_dfn!(operation, dfn)

        service = StateIisExchangeService.new

        case operation
        when :send then service.send_immunizations(dfn)
        when :query then service.query_history(dfn)
        when :process_responses then service.process_responses
        when :sync then service.sync_patient(dfn)
        end
      end

      private

      def validate_operation!(operation)
        raise ArgumentError, "Unknown IIS operation: #{operation}" unless VALID_OPERATIONS.include?(operation)
      end

      def validate_dfn!(operation, dfn)
        if OPERATIONS_REQUIRING_DFN.include?(operation) && (dfn.nil? || dfn.to_s.strip.empty?)
          raise ArgumentError, "DFN required for #{operation} operation"
        end
      end
    end
  end
end
