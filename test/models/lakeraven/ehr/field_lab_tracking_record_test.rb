# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FieldLabTrackingRecordTest < ActiveSupport::TestCase
      def reactive_screen(**overrides)
        FieldLabTrackingRecord.create!(
          {
            patient_ref: "panel-77", condition: "HCV",
            screening_test: "HCV Ab rapid", screening_result: "reactive",
            screening_recorded_at: Time.current, site_ien: "463", clinician_duz: "301"
          }.merge(overrides)
        )
      end

      test "requires patient_ref" do
        rec = FieldLabTrackingRecord.new(stage: "screened")
        refute rec.valid?
        assert rec.errors[:patient_ref].any?
      end

      test "rejects an unknown stage" do
        rec = reactive_screen
        rec.stage = "teleported"
        refute rec.valid?
      end

      test "a reactive screen with no confirmation result is awaiting confirmation" do
        rec = reactive_screen
        assert rec.awaiting_confirmation?
        assert_equal "confirmation", rec.awaiting
      end

      test "full arc: screen -> order -> confirm positive -> treat" do
        rec = reactive_screen
        assert_equal 1, rec.version

        rec.order_confirmation!(loinc: "13955-0", order_ref: "ORD-1")
        assert_equal "confirmation_ordered", rec.stage
        assert_equal 2, rec.version
        assert rec.awaiting_confirmation?

        rec.record_confirmation_result!(status: "positive", value: "detected")
        assert_equal "confirmed", rec.stage
        assert_equal 3, rec.version
        assert rec.awaiting_treatment?
        assert_equal "treatment", rec.awaiting

        rec.start_treatment!(medication: "Sofosbuvir/velpatasvir")
        assert_equal "treated", rec.stage
        assert_equal 4, rec.version
        assert rec.terminal?
        assert_nil rec.awaiting
      end

      test "negative confirmation closes the record without treatment" do
        rec = reactive_screen
        rec.order_confirmation!(loinc: "13955-0")
        rec.record_confirmation_result!(status: "negative")
        assert_equal "negative", rec.stage
        assert rec.terminal?
        refute rec.awaiting_treatment?
      end

      test "cannot order confirmation on a nonreactive screen" do
        rec = reactive_screen(screening_result: "nonreactive")
        assert_raises(FieldLabTrackingRecord::IllegalTransition) do
          rec.order_confirmation!(loinc: "13955-0")
        end
      end

      test "cannot record a result before ordering confirmation" do
        rec = reactive_screen
        assert_raises(FieldLabTrackingRecord::IllegalTransition) do
          rec.record_confirmation_result!(status: "positive")
        end
      end

      test "cannot treat before a positive confirmation" do
        rec = reactive_screen
        rec.order_confirmation!(loinc: "13955-0")
        assert_raises(FieldLabTrackingRecord::IllegalTransition) do
          rec.start_treatment!(medication: "x")
        end
      end

      test "mark_lost_to_followup records the reason and is terminal" do
        rec = reactive_screen
        rec.mark_lost_to_followup!(reason: "left site")
        assert rec.lost_to_followup?
        assert rec.terminal?
        assert_equal "left site", rec.details["lost_reason"]
      end

      test "cannot lose an already-terminal record" do
        rec = reactive_screen
        rec.order_confirmation!(loinc: "13955-0")
        rec.record_confirmation_result!(status: "negative")
        assert_raises(FieldLabTrackingRecord::IllegalTransition) { rec.mark_lost_to_followup! }
      end
    end
  end
end
