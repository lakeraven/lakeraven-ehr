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

      # S15: "six years" was written as 2190 days, but six CALENDAR years
      # span 2191–2192 days across leap years — so §164.528 disclosure
      # records were deleted one to two days INSIDE their retention window.
      # Pinned to a date where the six-year span contains two leap days
      # (2029-03-01 looks back across Feb 29 2024 AND Feb 29 2028 = 2192
      # days), where the day-count arithmetic is wrong by the most.
      test "a disclosure record still inside six calendar years survives the purge" do
        travel_to Time.zone.local(2029, 3, 1, 12) do
          disclosure = Disclosure.create!(
            patient_dfn: "1", recipient_name: "Example Payer",
            purpose: "TPO", data_disclosed: "claim", disclosed_by: "301",
            disclosed_at: Time.zone.local(2023, 3, 2, 12),
            created_at: Time.zone.local(2023, 3, 2, 12)
          )

          DataRetentionJob.perform_now

          assert Disclosure.exists?(disclosure.id),
            "a §164.528 disclosure record was deleted 1–2 days inside its six-year window"
        end
      ensure
        Disclosure.delete_all
      end

      test "a disclosure record past six calendar years is purged" do
        travel_to Time.zone.local(2029, 3, 1, 12) do
          disclosure = Disclosure.create!(
            patient_dfn: "1", recipient_name: "Example Payer",
            purpose: "TPO", data_disclosed: "claim", disclosed_by: "301",
            disclosed_at: Time.zone.local(2023, 2, 27, 12),
            created_at: Time.zone.local(2023, 2, 27, 12)
          )

          DataRetentionJob.perform_now

          refute Disclosure.exists?(disclosure.id),
            "a disclosure past its window was retained by the purge"
        end
      ensure
        Disclosure.delete_all
      end

      # A refused purge is an ERROR the operator must see, not a "skip": a
      # skip reads as routine, and a purge that silently never runs leaves
      # an unbounded log nobody notices.
      test "a below-floor retention policy surfaces as an error, not a routine skip" do
        Lakeraven::EHR.configure { |c| c.audit_retention_period = 30.days }

        result = DataRetentionJob.perform_now

        assert result["AuditEvent"][:error].present?,
          "a policy violation was reported as a routine skip"
      ensure
        Lakeraven::EHR.reset_configuration!
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
