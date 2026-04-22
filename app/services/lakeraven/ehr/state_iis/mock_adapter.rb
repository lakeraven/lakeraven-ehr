# frozen_string_literal: true

module Lakeraven
  module EHR
    module StateIis
      class MockAdapter
        attr_reader :sent_dfns, :queried_dfns

        def initialize
          @sent_dfns = []
          @queried_dfns = []
          @connection_failure = false
          @pending_responses = false
          @custom_immunizations = []
        end

        def send_immunizations(dfn)
          return Result.failure(message: "state IIS connection unavailable") if @connection_failure

          @sent_dfns << dfn.to_s
          Result.success(data: { operation: :sent, dfn: dfn.to_s })
        end

        def query_history(dfn)
          return Result.failure(message: "state IIS connection unavailable") if @connection_failure

          @queried_dfns << dfn.to_s
          immunizations = %w[1 2].include?(dfn.to_s) ? default_immunizations + @custom_immunizations : []
          Result.success(data: { immunizations: immunizations })
        end

        def process_responses
          return Result.failure(message: "state IIS connection unavailable") if @connection_failure

          Result.success(data: { operation: :processed, count: @pending_responses ? 3 : 0 })
        end

        def connection_status
          { available: !@connection_failure, adapter: "mock" }
        end

        def simulate_connection_failure!
          @connection_failure = true
        end

        def seed_pending_responses
          @pending_responses = true
        end

        def seed_query_response(vaccine:, date:)
          @custom_immunizations << {
            vaccine_code: "999", vaccine_display: vaccine,
            occurrence_date: Date.parse(date.to_s), status: "completed"
          }
        end

        private

        def default_immunizations
          [
            { vaccine_code: "08", vaccine_display: "Hep B", occurrence_date: Date.parse("2023-06-15"), status: "completed" },
            { vaccine_code: "140", vaccine_display: "Influenza", occurrence_date: Date.parse("2023-10-01"), status: "completed" }
          ]
        end
      end
    end
  end
end
