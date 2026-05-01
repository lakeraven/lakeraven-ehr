# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class StateIisExchangeServiceTest < ActiveSupport::TestCase
      test "send_immunizations succeeds with mock adapter" do
        service = StateIisExchangeService.new
        result = service.send_immunizations("pt_001")

        assert result.success?
      end

      test "send_immunizations returns failure when disabled" do
        service = StateIisExchangeService.new(enabled: false)
        result = service.send_immunizations("pt_001")

        assert result.failure?
        assert_includes result.message, "disabled"
      end

      test "send_immunizations returns failure when facility code missing" do
        service = StateIisExchangeService.new(facility_code: nil)
        result = service.send_immunizations("pt_001")

        assert result.failure?
        assert_includes result.message, "facility code"
      end

      test "query_history succeeds with mock adapter" do
        service = StateIisExchangeService.new
        result = service.query_history("pt_001")

        assert result.success?
      end

      test "query_history returns failure when disabled" do
        service = StateIisExchangeService.new(enabled: false)
        result = service.query_history("pt_001")

        assert result.failure?
      end

      test "process_responses succeeds with mock adapter" do
        service = StateIisExchangeService.new
        result = service.process_responses

        assert result.success?
      end

      test "sync_patient orchestrates query and process" do
        service = StateIisExchangeService.new
        result = service.sync_patient("pt_001")

        assert result.success?
        assert_equal "pt_001", result.data[:dfn]
      end
    end
  end
end
