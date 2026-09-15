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

      # This job deleted PHI access records after 365 days — five years inside
      # the window §164.316(b)(2)(i) requires, on a low-priority queue, with
      # nothing but a count returned. The old test asserted that the policy
      # constant existed, never that its number was lawful.
      test "the job cannot purge a PHI access record inside its retention window" do
        AuditEvent.delete_all
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Practitioner", agent_who_identifier: "301"
        )

        travel_to 2.years.from_now do
          DataRetentionJob.perform_now

          assert AuditEvent.exists?(event.id),
            "a PHI access record was destroyed #{Lakeraven::EHR::Configuration::MINIMUM_AUDIT_RETENTION.inspect} " \
            "before policy allows"
        end
      end

      test "a PHI access record past its retention window is purged, with a receipt" do
        AuditEvent.delete_all
        AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Practitioner", agent_who_identifier: "301"
        )

        travel_to 6.years.from_now + 1.day do
          DataRetentionJob.perform_now

          assert_equal 0, AuditEvent.where(event_type: "rest").count
          assert_equal "D", AuditEvent.order(:id).last.action, "the purge left no receipt"
        end
      end
    end
  end
end
