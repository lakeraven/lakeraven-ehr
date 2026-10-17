# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthProgramConfigurationMalformedPartsTest < ActiveSupport::TestCase
      setup do
        BehavioralHealthProgramConfiguration.reset!
      end

      test "duration_from accepts a hash of unit parts" do
        assert_equal 60.days, BehavioralHealthProgramConfiguration.duration_from({ "days" => 60 })
      end

      test "duration_from raises ArgumentError for a string stored value" do
        assert_raises(ArgumentError) { BehavioralHealthProgramConfiguration.duration_from("60") }
      end

      test "duration_from raises ArgumentError for an integer stored value" do
        assert_raises(ArgumentError) { BehavioralHealthProgramConfiguration.duration_from(60) }
      end

      test "duration_from raises ArgumentError for a bare array stored value" do
        assert_raises(ArgumentError) { BehavioralHealthProgramConfiguration.duration_from([ 60 ]) }
      end

      test "duration_from raises ArgumentError for an array-of-pairs stored value" do
        assert_raises(ArgumentError) do
          BehavioralHealthProgramConfiguration.duration_from([ [ "months", 1 ] ])
        end
      end

      test "progress_review_interval raises ArgumentError when jsonb holds a string" do
        program_key = "malformed_progress_string"
        assign_program(program_key)
        record = BehavioralHealthProgramConfiguration.for_program(program_key)
        record.update_column(:progress_review_interval_parts, "60")

        reloaded = BehavioralHealthProgramConfiguration.find(record.id)

        assert_raises(ArgumentError) { reloaded.progress_review_interval }
      end

      test "progress_review_interval raises ArgumentError when jsonb holds an integer" do
        program_key = "malformed_progress_integer"
        assign_program(program_key)
        record = BehavioralHealthProgramConfiguration.for_program(program_key)
        record.update_column(:progress_review_interval_parts, 60)

        reloaded = BehavioralHealthProgramConfiguration.find(record.id)

        assert_raises(ArgumentError) { reloaded.progress_review_interval }
      end

      test "progress_review_interval raises ArgumentError when jsonb holds an array" do
        program_key = "malformed_progress_array"
        assign_program(program_key)
        record = BehavioralHealthProgramConfiguration.for_program(program_key)
        record.update_column(:progress_review_interval_parts, [ 60 ])

        reloaded = BehavioralHealthProgramConfiguration.find(record.id)

        assert_raises(ArgumentError) { reloaded.progress_review_interval }
      end

      test "end_of_treatment_review_interval raises ArgumentError when jsonb holds a string" do
        program_key = "malformed_eot_string"
        assign_program(program_key)
        record = BehavioralHealthProgramConfiguration.for_program(program_key)
        record.update_column(:end_of_treatment_review_interval_parts, "60")

        reloaded = BehavioralHealthProgramConfiguration.find(record.id)

        assert_raises(ArgumentError) { reloaded.end_of_treatment_review_interval }
      end

      test "end_of_treatment_review_interval raises ArgumentError when jsonb holds an integer" do
        program_key = "malformed_eot_integer"
        assign_program(program_key)
        record = BehavioralHealthProgramConfiguration.for_program(program_key)
        record.update_column(:end_of_treatment_review_interval_parts, 60)

        reloaded = BehavioralHealthProgramConfiguration.find(record.id)

        assert_raises(ArgumentError) { reloaded.end_of_treatment_review_interval }
      end

      test "end_of_treatment_review_interval raises ArgumentError when jsonb holds an array" do
        program_key = "malformed_eot_array"
        assign_program(program_key)
        record = BehavioralHealthProgramConfiguration.for_program(program_key)
        record.update_column(:end_of_treatment_review_interval_parts, [ 60 ])

        reloaded = BehavioralHealthProgramConfiguration.find(record.id)

        assert_raises(ArgumentError) { reloaded.end_of_treatment_review_interval }
      end

      def assign_program(program_key)
        BehavioralHealthProgramConfiguration.assign(
          program_key: program_key,
          progress_review_interval: 60.days,
          end_of_treatment_review_interval: 6.months
        )
      end
    end
  end
end
