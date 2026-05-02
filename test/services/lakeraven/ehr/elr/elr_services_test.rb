# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module Elr
      class ElrServicesTest < ActiveSupport::TestCase
        test "submit succeeds with mock adapter" do
          adapter = MockEclrsAdapter.new
          service = EclrsTransmissionService.new(adapter: adapter)

          result = service.submit(
            oru_message: "MSH|^~\\&|Lab|ECLRS||...",
            patient_dfn: "12345",
            provider_duz: "789"
          )

          assert result[:success]
          assert result[:tracking_id].present?
        end

        test "submit creates audit event" do
          adapter = MockEclrsAdapter.new
          service = EclrsTransmissionService.new(adapter: adapter)

          assert_difference "AuditEvent.count", 1 do
            service.submit(
              oru_message: "MSH|^~\\&|Lab|ECLRS||...",
              patient_dfn: "12345",
              provider_duz: "789"
            )
          end
        end

        test "submit records transmission in adapter" do
          adapter = MockEclrsAdapter.new
          service = EclrsTransmissionService.new(adapter: adapter)

          service.submit(
            oru_message: "MSH|^~\\&|Lab|ECLRS||...",
            patient_dfn: "12345",
            provider_duz: "789"
          )

          assert_equal 1, adapter.submissions.size
        end

        test "submit audits failure when adapter raises" do
          failing_adapter = Object.new
          failing_adapter.define_singleton_method(:transmit) { |_msg| raise "Connection refused" }
          service = EclrsTransmissionService.new(adapter: failing_adapter)

          result = nil
          assert_difference "AuditEvent.count", 1 do
            result = service.submit(
              oru_message: "MSH|^~\\&|Lab|ECLRS||...",
              patient_dfn: "12345",
              provider_duz: "789"
            )
          end

          refute result[:success]
        end

        test "mock adapter tracks submissions" do
          adapter = MockEclrsAdapter.new

          result = adapter.transmit("MSH|^~\\&|Lab|ECLRS||...")

          assert result[:success]
          assert result[:tracking_id].present?
          assert_equal 1, adapter.submissions.size
        end
      end
    end
  end
end
