# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MedicationRequestUsCoreRequiredElementsTest < ActiveSupport::TestCase
      DATA_ABSENT_REASON_URL = "http://hl7.org/fhir/StructureDefinition/data-absent-reason"

      def wire_medication_row(overrides = {})
        {
          ien: "42",
          drug_name: "Metformin 500mg",
          stop_date: nil,
          route: "PO",
          schedule: "BID",
          refills: 2
        }.merge(overrides)
      end

      def assert_authored_on_data_absent_unknown(fhir)
        assert_nil fhir[:authoredOn]
        dar = fhir.dig(:_authoredOn, :extension)&.find { |ext| ext[:url] == DATA_ABSENT_REASON_URL }
        assert dar, "expected data-absent-reason on _authoredOn"
        assert_equal "unknown", dar[:valueCode]
      end

      def assert_requester_data_absent_unknown(requester)
        assert_nil requester&.dig(:reference)
        assert_nil requester&.dig(:display)
        dar = requester&.dig(:extension)&.find { |ext| ext[:url] == DATA_ABSENT_REASON_URL }
        assert dar, "expected data-absent-reason on requester"
        assert_equal "unknown", dar[:valueCode]
      end

      def assert_stop_date_absent_from_fhir(fhir, stop_date)
        refute fhir.dig(:dispenseRequest, :validityPeriod),
               "stop_date must not appear as dispenseRequest.validityPeriod"

        fragments = [ stop_date.to_s ]
        if stop_date.is_a?(Date)
          fragments << RpmsRpc::FilemanDateParser.format_date(stop_date)
          fragments << stop_date.iso8601
        elsif stop_date.to_s.match?(/\A\d{7}\z/)
          parsed = RpmsRpc::FilemanDateParser.parse_date(stop_date)
          fragments << parsed.iso8601 if parsed
        end

        serialized = fhir.deep_stringify_keys.to_json
        fragments.compact.uniq.each do |fragment|
          refute_includes serialized, fragment,
                          "stop_date must not leak into FHIR serialization (#{fragment})"
        end
      end

      test "to_fhir emits authoredOn as ISO 8601 when authored_on is present" do
        dt = DateTime.new(2024, 6, 3, 14, 30, 0)
        mr = MedicationRequest.new(
          ien: "1",
          patient_dfn: "100",
          medication_display: "Lisinopril",
          status: "active",
          intent: "order",
          authored_on: dt
        )
        fhir = mr.to_fhir

        assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/, fhir[:authoredOn].to_s,
                     "authoredOn must be a FHIR dateTime with a time zone")
        assert_equal dt.to_time.to_i, Time.iso8601(fhir[:authoredOn]).to_i
        refute fhir.key?(:_authoredOn), "must not emit _authoredOn when authored_on is present"
      end

      test "to_fhir emits _authoredOn data-absent-reason when authored_on is blank" do
        mr = MedicationRequest.new(
          ien: "1",
          patient_dfn: "100",
          medication_display: "Lisinopril",
          status: "unknown",
          intent: "order"
        )

        assert_authored_on_data_absent_unknown(mr.to_fhir)
      end

      test "to_fhir includes requester reference when requester_duz is present" do
        mr = MedicationRequest.new(
          ien: "1",
          patient_dfn: "100",
          medication_display: "Lisinopril",
          status: "active",
          intent: "order",
          requester_duz: "789",
          requester_name: "Dr. Smith"
        )
        fhir = mr.to_fhir

        assert_equal "Practitioner/789", fhir.dig(:requester, :reference)
        assert_equal "Dr. Smith", fhir.dig(:requester, :display)
        refute fhir.dig(:requester, :extension)&.any? { |ext| ext[:url] == DATA_ABSENT_REASON_URL },
               "requester must not carry data-absent-reason when requester_duz is present"
      end

      test "to_fhir emits extension-only requester when requester_duz is blank" do
        mr = MedicationRequest.new(
          ien: "1",
          patient_dfn: "100",
          medication_display: "Lisinopril",
          status: "unknown",
          intent: "order"
        )

        assert_requester_data_absent_unknown(mr.to_fhir[:requester])
      end

      test "to_fhir does not invent requester reference when only requester_name is present" do
        mr = MedicationRequest.new(
          ien: "1",
          patient_dfn: "100",
          medication_display: "Lisinopril",
          status: "unknown",
          intent: "order",
          requester_name: "Dr. Smith"
        )

        assert_requester_data_absent_unknown(mr.to_fhir[:requester])
      end

      test "from_rpms_row serialization includes every US Core 3.1.1 required MedicationRequest element" do
        mr = MedicationRequest.from_rpms_row(wire_medication_row, patient_dfn: "1")
        fhir = mr.to_fhir

        assert_equal "MedicationRequest", fhir[:resourceType]
        assert fhir[:status].present?, "status is required"
        assert_equal "order", fhir[:intent]
        assert fhir.dig(:medicationCodeableConcept, :text).present?, "medicationCodeableConcept is required"
        assert fhir.dig(:subject, :reference).present?, "subject.reference is required"

        assert_authored_on_data_absent_unknown(fhir)
        assert_requester_data_absent_unknown(fhir[:requester])
      end

      test "from_rpms_row does not map stop_date to authoredOn, status, or dispense validityPeriod" do
        [ Date.new(2025, 1, 1), "3250101" ].each do |stop_date|
          fhir = MedicationRequest.from_rpms_row(
            wire_medication_row(stop_date: stop_date),
            patient_dfn: "1"
          ).to_fhir

          assert_equal "unknown", fhir[:status]
          assert_authored_on_data_absent_unknown(fhir)
          assert_stop_date_absent_from_fhir(fhir, stop_date)
        end
      end
    end
  end
end
