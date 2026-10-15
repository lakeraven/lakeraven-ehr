# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthVisitCodingGateR1Test < ActiveSupport::TestCase
      EVAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_PSYCHIATRIC_DIAGNOSTIC_EVALUATION
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      PATIENT_DFN = 8801
      ENCOUNTER_IEN = "2090061"
      DOCUMENTED_BY_DUZ = "2843"

      teardown { BehavioralHealthVisitCoding.delete_all }

      def base_row_attributes(**overrides)
        {
          patient_dfn: PATIENT_DFN,
          encounter_ien: ENCOUNTER_IEN,
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: DOCUMENTED_BY_DUZ
        }.merge(overrides)
      end

      def insert_timestamp_attributes
        now = Time.current
        { created_at: now, updated_at: now }
      end

      test "B4 raw insert of individual psychotherapy with null duration and cpt 90837 is rejected by the database" do
        assert_raises(ActiveRecord::StatementInvalid) do
          BehavioralHealthVisitCoding.insert_all(
            [ base_row_attributes(
              encounter_ien: "gate-b4-individual-null-duration",
              encounter_kind: INDIVIDUAL,
              duration_minutes: nil,
              cpt_code: "90837"
            ).merge(insert_timestamp_attributes) ]
          )
        end
      end

      test "B4 raw insert of psychiatric diagnostic evaluation with null cpt_code is rejected by the database" do
        assert_raises(ActiveRecord::StatementInvalid) do
          BehavioralHealthVisitCoding.insert_all(
            [ base_row_attributes(
              encounter_ien: "gate-b4-eval-null-cpt",
              encounter_kind: EVAL,
              duration_minutes: nil,
              cpt_code: nil,
              selected_cpt_code: nil
            ).merge(insert_timestamp_attributes) ]
          )
        end
      end

      test "B4 raw insert of individual psychotherapy with 45 minutes and null derived and selected cpt is rejected by the database" do
        assert_raises(ActiveRecord::StatementInvalid) do
          BehavioralHealthVisitCoding.insert_all(
            [ base_row_attributes(
              encounter_ien: "gate-b4-individual-45-null-cpt",
              encounter_kind: INDIVIDUAL,
              duration_minutes: 45,
              cpt_code: nil,
              selected_cpt_code: nil
            ).merge(insert_timestamp_attributes) ]
          )
        end
      end

      test "B6 psychiatric diagnostic evaluation with negative duration is refused with invalid_duration" do
        record = BehavioralHealthVisitCoding.new(
          base_row_attributes(encounter_kind: EVAL, duration_minutes: -5)
        )

        refute record.valid?
        refute record.resolved?
        assert_equal :invalid_duration, record.blocking_reason
      end

      test "B6 psychiatric diagnostic evaluation with nil duration still resolves to 90791" do
        record = BehavioralHealthVisitCoding.new(
          base_row_attributes(encounter_kind: EVAL, duration_minutes: nil)
        )

        assert record.valid?, record.errors.full_messages.inspect
        assert record.resolved?
        assert_equal "90791", record.cpt_code
      end

      test "B3 direct second create for the same patient_dfn and encounter_ien raises RecordNotUnique" do
        BehavioralHealthVisitCoding.create!(base_row_attributes)

        assert_raises(ActiveRecord::RecordNotUnique) do
          BehavioralHealthVisitCoding.create!(base_row_attributes)
        end
      end
    end
  end
end
