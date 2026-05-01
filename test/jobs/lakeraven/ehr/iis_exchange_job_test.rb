# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class IisExchangeJobTest < ActiveSupport::TestCase
      test "perform :send dispatches to send_immunizations" do
        result = IisExchangeJob.perform_now(operation: :send, dfn: "1")

        assert result.success?
      end

      test "perform :query dispatches to query_history" do
        result = IisExchangeJob.perform_now(operation: :query, dfn: "1")

        assert result.success?
      end

      test "perform :process_responses dispatches to process_responses" do
        result = IisExchangeJob.perform_now(operation: :process_responses)

        assert result.success?
      end

      test "perform :sync dispatches to sync_patient" do
        result = IisExchangeJob.perform_now(operation: :sync, dfn: "1")

        assert result.success?
      end

      test "perform raises on unknown operation" do
        assert_raises(ArgumentError) do
          IisExchangeJob.perform_now(operation: :unknown)
        end
      end

      test "perform raises when dfn required but missing" do
        assert_raises(ArgumentError) do
          IisExchangeJob.perform_now(operation: :send, dfn: nil)
        end
      end

      test "job uses integrations queue" do
        assert_equal "integrations", IisExchangeJob.new.queue_name
      end
    end
  end
end
