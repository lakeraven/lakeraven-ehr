# frozen_string_literal: true

module Lakeraven
  module EHR
    class StateIisExchangeService
      FailingAdapter = Class.new do
        def send_immunizations(_dfn) = StateIis::Result.failure(message: "connection refused")
        def query_history(_dfn) = StateIis::Result.failure(message: "connection refused")
        def process_responses = StateIis::Result.failure(message: "connection refused")
        def connection_status = { available: false, adapter: "failing" }
      end

      attr_reader :adapter

      def initialize(enabled: true, facility_code: "DEFAULT", adapter: nil)
        @enabled = enabled
        @facility_code = facility_code
        @adapter = adapter || StateIis::MockAdapter.new
      end

      def send_immunizations(dfn)
        return disabled_result unless @enabled
        return config_error_result unless @facility_code.present?

        adapter.send_immunizations(dfn)
      end

      def query_history(dfn)
        return disabled_result unless @enabled

        adapter.query_history(dfn)
      end

      def process_responses
        return disabled_result unless @enabled

        adapter.process_responses
      end

      def sync_patient(dfn)
        return disabled_result unless @enabled

        query_result = adapter.query_history(dfn)
        return StateIis::Result.failure(message: "Query failed") if query_result.failure?

        process_result = adapter.process_responses
        return StateIis::Result.failure(message: "Processing failed") if process_result.failure?

        StateIis::Result.success(data: {
          query_result: query_result,
          process_result: process_result,
          dfn: dfn.to_s
        })
      end

      private

      def disabled_result
        StateIis::Result.failure(message: "State IIS exchange is disabled")
      end

      def config_error_result
        StateIis::Result.failure(message: "State IIS configuration error: facility code required")
      end
    end
  end
end
