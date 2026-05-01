# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DataRetentionJobTest < ActiveSupport::TestCase
      test "job can be instantiated" do
        job = DataRetentionJob.new
        assert_kind_of DataRetentionJob, job
      end

      test "job uses low_priority queue" do
        assert_equal "low_priority", DataRetentionJob.new.queue_name
      end

      test "perform returns results hash" do
        result = DataRetentionJob.perform_now

        assert_kind_of Hash, result
      end

      test "perform completes without errors" do
        assert_nothing_raised do
          DataRetentionJob.perform_now
        end
      end

      test "RETENTION_POLICIES is defined" do
        assert DataRetentionJob::RETENTION_POLICIES.is_a?(Hash)
        assert DataRetentionJob::RETENTION_POLICIES.any?
      end
    end
  end
end
