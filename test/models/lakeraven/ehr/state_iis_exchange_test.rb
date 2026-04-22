# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class StateIisExchangeTest < ActiveSupport::TestCase
      setup do
        @service = StateIisExchangeService.new
      end

      # -- Send immunizations --------------------------------------------------

      test "send succeeds when enabled" do
        result = @service.send_immunizations("1")
        assert result.success?
      end

      test "send fails when disabled" do
        service = StateIisExchangeService.new(enabled: false)
        result = service.send_immunizations("1")
        assert result.failure?
        assert_includes result.message.downcase, "disabled"
      end

      # -- Query history -------------------------------------------------------

      test "query returns immunization records" do
        result = @service.query_history("1")
        assert result.success?
      end

      test "query for unknown patient succeeds with empty records" do
        result = @service.query_history("999")
        assert result.success?
        assert_equal 0, result.record_count
      end

      # -- Process responses ---------------------------------------------------

      test "process pending responses succeeds" do
        result = @service.process_responses
        assert result.success?
      end

      # -- Sync ----------------------------------------------------------------

      test "sync combines query and process" do
        result = @service.sync_patient("1")
        assert result.success?
      end

      # -- Configuration errors ------------------------------------------------

      test "send fails with configuration error when facility code missing" do
        service = StateIisExchangeService.new(facility_code: nil)
        result = service.send_immunizations("1")
        assert result.failure?
        assert_includes result.message.downcase, "configuration"
      end

      # -- Connection errors ---------------------------------------------------

      test "send fails with connection error when adapter unavailable" do
        service = StateIisExchangeService.new(adapter: StateIisExchangeService::FailingAdapter.new)
        result = service.send_immunizations("1")
        assert result.failure?
        assert_includes result.message.downcase, "connection"
      end

      # -- Adapter selection ---------------------------------------------------

      test "default adapter is mock" do
        assert_kind_of StateIis::MockAdapter, @service.adapter
      end

      test "adapter responds to connection_status" do
        assert @service.adapter.connection_status[:available]
      end
    end
  end
end
