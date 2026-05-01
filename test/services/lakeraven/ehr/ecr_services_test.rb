# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EcrServicesTest < ActiveSupport::TestCase
      setup do
        AuditEvent.delete_all
      end

      # =============================================================================
      # REPORTABILITY RESPONSE PROCESSOR
      # =============================================================================

      test "processes reportable determination" do
        result = ReportabilityResponseProcessor.process(
          eicr_id: "eicr-001", patient_dfn: "12345",
          determination: "reportable", jurisdiction: "NY"
        )

        assert result[:success]
        assert_equal "reportable", result[:determination]
        assert_equal "eicr-001", result[:eicr_id]
      end

      test "processes not reportable determination" do
        result = ReportabilityResponseProcessor.process(
          eicr_id: "eicr-002", patient_dfn: "12345",
          determination: "not reportable", jurisdiction: "NY"
        )

        assert result[:success]
        assert_equal "not reportable", result[:determination]
      end

      test "processes may be reportable determination" do
        result = ReportabilityResponseProcessor.process(
          eicr_id: "eicr-003", patient_dfn: "12345",
          determination: "may be reportable", jurisdiction: "NY"
        )

        assert result[:success]
        assert_equal "may be reportable", result[:determination]
      end

      # =============================================================================
      # ECLRS TRANSMISSION SERVICE
      # =============================================================================

      test "submit succeeds with mock adapter" do
        adapter = Ecr::MockEclrsAdapter.new
        service = Ecr::EclrsTransmissionService.new(adapter: adapter)

        result = service.submit(
          eicr_xml: "<xml>test</xml>",
          patient_dfn: "12345",
          provider_duz: "789"
        )

        assert result[:success]
        assert result[:tracking_id].present?
      end

      test "submit creates audit event" do
        adapter = Ecr::MockEclrsAdapter.new
        service = Ecr::EclrsTransmissionService.new(adapter: adapter)

        assert_difference "AuditEvent.count", 1 do
          service.submit(
            eicr_xml: "<xml>test</xml>",
            patient_dfn: "12345",
            provider_duz: "789"
          )
        end
      end

      test "submit records transmission in adapter" do
        adapter = Ecr::MockEclrsAdapter.new
        service = Ecr::EclrsTransmissionService.new(adapter: adapter)

        service.submit(
          eicr_xml: "<xml>test</xml>",
          patient_dfn: "12345",
          provider_duz: "789"
        )

        assert_equal 1, adapter.submissions.size
      end

      test "mock adapter tracks submissions" do
        adapter = Ecr::MockEclrsAdapter.new

        result = adapter.transmit("<xml>eicr</xml>")

        assert result[:success]
        assert result[:tracking_id].present?
        assert_equal 1, adapter.submissions.size
      end
    end
  end
end
