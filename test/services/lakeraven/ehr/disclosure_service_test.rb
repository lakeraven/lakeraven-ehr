# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DisclosureServiceTest < ActiveSupport::TestCase
      setup do
        Disclosure.delete_all
        AuditEvent.delete_all
        @attrs = {
          patient_dfn: "12345",
          recipient_name: "County Health Dept",
          recipient_type: "Public Health Authority",
          purpose: "public_health",
          data_disclosed: "Laboratory results, Demographics",
          disclosed_by: "789"
        }
      end

      # =========================================================================
      # RECORDING
      # =========================================================================

      test "record creates a disclosure" do
        disclosure = DisclosureService.record(**@attrs)
        assert disclosure.persisted?
        assert_equal "12345", disclosure.patient_dfn
        assert_equal "public_health", disclosure.purpose
      end

      test "record sets disclosed_at to current time when not provided" do
        disclosure = DisclosureService.record(**@attrs)
        assert_in_delta Time.current, disclosure.disclosed_at, 2.seconds
      end

      test "record accepts explicit disclosed_at" do
        time = 3.days.ago
        disclosure = DisclosureService.record(**@attrs, disclosed_at: time)
        assert_in_delta time, disclosure.disclosed_at, 1.second
      end

      test "record creates an audit event" do
        disclosure = DisclosureService.record(**@attrs)
        audit = AuditEvent.where(entity_type: "Disclosure").last
        assert audit.present?
        assert_equal "C", audit.action
        assert_equal disclosure.id.to_s, audit.entity_id
        assert_equal "789", audit.agent_who_identifier
        assert_equal "Practitioner", audit.agent_who_type
      end

      test "record raises on invalid data" do
        assert_raises(ActiveRecord::RecordInvalid) do
          DisclosureService.record(**@attrs.merge(patient_dfn: ""))
        end
      end

      # =========================================================================
      # ACCOUNTING
      # =========================================================================

      test "accounting returns disclosures for a patient" do
        DisclosureService.record(**@attrs)
        DisclosureService.record(**@attrs.merge(patient_dfn: "99999"))

        result = DisclosureService.accounting("12345")
        assert_equal 1, result.count
      end

      test "accounting excludes disclosures older than 6 years" do
        DisclosureService.record(**@attrs, disclosed_at: 5.years.ago)
        DisclosureService.record(**@attrs, disclosed_at: 7.years.ago)

        result = DisclosureService.accounting("12345")
        assert_equal 1, result.count
      end

      # =========================================================================
      # EXPORT
      # =========================================================================

      test "export_report returns structured hash" do
        DisclosureService.record(**@attrs)

        report = DisclosureService.export_report("12345")
        assert_equal "12345", report[:patient_dfn]
        assert_equal "accounting_of_disclosures", report[:report_type]
        assert report[:period_start].present?
        assert report[:period_end].present?
        assert_equal 1, report[:total_disclosures]
        assert_equal 1, report[:disclosures].length
      end

      test "export_report includes disclosure details" do
        DisclosureService.record(**@attrs)

        report = DisclosureService.export_report("12345")
        entry = report[:disclosures].first
        assert_equal "County Health Dept", entry[:recipient][:name]
        assert_equal "Public Health Authority", entry[:recipient][:type]
        assert_equal "public_health", entry[:purpose]
      end
    end
  end
end
