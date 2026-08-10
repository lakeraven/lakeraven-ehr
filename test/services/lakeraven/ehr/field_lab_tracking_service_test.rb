# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FieldLabTrackingServiceTest < ActiveSupport::TestCase
      setup { @service = FieldLabTrackingService.new }

      test "screen opens a tracking record at the screened stage" do
        rec = @service.screen(
          patient_ref: "panel-9", condition: "Syphilis",
          screening_test: "RPR rapid", screening_result: "reactive", site_ien: "463"
        )
        assert rec.persisted?
        assert_equal "screened", rec.stage
        assert_equal 1, rec.version
      end

      test "work_queue surfaces reactive screens awaiting confirmation" do
        @service.screen(patient_ref: "p1", condition: "HCV", screening_result: "reactive", site_ien: "463")
        @service.screen(patient_ref: "p2", condition: "HCV", screening_result: "nonreactive", site_ien: "463")

        queue = @service.work_queue(site_ien: "463")
        assert_equal 1, queue.size
        assert_equal "p1", queue.first[:patient_ref]
        assert_equal "confirmation", queue.first[:awaiting]
      end

      test "work_queue surfaces confirmed-positive records awaiting treatment" do
        rec = @service.screen(patient_ref: "p3", condition: "HCV", screening_result: "reactive", site_ien: "463")
        rec.order_confirmation!(loinc: "13955-0")
        rec.record_confirmation_result!(status: "positive")

        queue = @service.work_queue(site_ien: "463")
        entry = queue.find { |e| e[:patient_ref] == "p3" }
        assert_equal "treatment", entry[:awaiting]
      end

      test "treated records drop off the work queue" do
        rec = @service.screen(patient_ref: "p4", condition: "HCV", screening_result: "reactive", site_ien: "463")
        rec.order_confirmation!(loinc: "13955-0")
        rec.record_confirmation_result!(status: "positive")
        rec.start_treatment!(medication: "SOF/VEL")

        assert_empty @service.work_queue(site_ien: "463")
      end

      # -- handler protocol --------------------------------------------------

      def op(payload:, **overrides)
        FieldSyncService::Operation.new(
          { client_op_id: "x", operation_type: "create", target_type: "FieldLabTracking", payload: payload }.merge(overrides)
        )
      end

      test "create builds a record from a sync operation payload" do
        rec = @service.create(op(payload: { patient_ref: "p5", condition: "HIV", screening_result: "reactive" }))
        assert_equal "p5", rec.patient_ref
        assert_equal 1, @service.version_of(rec)
      end

      test "apply advances the arc and raises on an unknown action" do
        rec = @service.create(op(payload: { patient_ref: "p6", screening_result: "reactive" }))
        @service.apply(rec, op(operation_type: "update", payload: { action: "order_confirmation", confirmation_loinc: "13955-0" }))
        assert_equal "confirmation_ordered", rec.stage

        assert_raises(FieldLabTrackingService::UnknownAction) do
          @service.apply(rec, op(operation_type: "update", payload: { action: "levitate" }))
        end
      end
    end
  end
end
