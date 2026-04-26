# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class VfcComplianceAuditServiceTest < ActiveSupport::TestCase
      # =========================================================================
      # REPORT GENERATION
      # =========================================================================

      test "generate_report returns VfcComplianceReport" do
        report = generate(immunizations: [ build_imm ], lots: [ build_lot ])

        assert_kind_of VfcComplianceAuditService::VfcComplianceReport, report
      end

      test "generate_report sets date range and facility" do
        report = generate(immunizations: [ build_imm ], lots: [ build_lot ], facility_ien: "FAC1")

        assert_equal Date.new(2026, 1, 1)..Date.new(2026, 3, 1), report.date_range
        assert_equal "FAC1", report.facility
        assert report.generated_at.present?
      end

      test "generate_report includes immunization records" do
        report = generate(immunizations: [ build_imm ], lots: [ build_lot ])

        assert report.immunization_records.is_a?(Array)
      end

      # =========================================================================
      # COMPLIANCE FLAGS
      # =========================================================================

      test "flags immunizations with missing VIS edition date" do
        report = generate(
          immunizations: [ build_imm(vis_edition_date: nil, vis_presentation_date: Date.new(2026, 1, 15)) ],
          lots: [ build_lot ]
        )

        missing_vis = report.findings.select { |f| f[:type] == "missing_vis" }
        assert missing_vis.any?, "Expected missing_vis flag"
        assert_includes missing_vis.first[:description], "edition date"
      end

      test "flags immunizations with missing VIS presentation date" do
        report = generate(
          immunizations: [ build_imm(vis_edition_date: Date.new(2025, 8, 1), vis_presentation_date: nil) ],
          lots: [ build_lot ]
        )

        missing_vis = report.findings.select { |f| f[:type] == "missing_vis" }
        assert missing_vis.any?
        assert_includes missing_vis.first[:description], "presentation date"
      end

      test "flags expired lots at administration time" do
        report = generate(
          immunizations: [ build_imm ],
          lots: [ build_lot(expiration_date: Date.new(2025, 12, 31)) ]
        )

        expired = report.findings.select { |f| f[:type] == "expired_lot" }
        assert expired.any?, "Expected expired_lot flag"
      end

      test "flags VFC-ineligible patients who received VFC vaccines" do
        report = generate(
          immunizations: [ build_imm(vfc_eligibility_code: "V01", funding_source: "VFC") ],
          lots: [ build_lot ]
        )

        ineligible = report.findings.select { |f| f[:type] == "vfc_ineligible" }
        assert ineligible.any?, "Expected vfc_ineligible flag"
      end

      test "flags VFC-funded records with missing eligibility code" do
        report = generate(
          immunizations: [ build_imm(vfc_eligibility_code: nil, funding_source: "VFC") ],
          lots: [ build_lot ]
        )

        unknown = report.findings.select { |f| f[:type] == "vfc_eligibility_unknown" }
        assert unknown.any?, "Expected vfc_eligibility_unknown flag"
      end

      test "no flags for compliant immunizations" do
        report = generate(
          immunizations: [ build_imm(
            vis_edition_date: Date.new(2025, 8, 1),
            vis_presentation_date: Date.new(2026, 1, 15),
            vfc_eligibility_code: "V02",
            funding_source: "VFC"
          ) ],
          lots: [ build_lot(expiration_date: Date.new(2027, 6, 30)) ]
        )

        assert report.compliant?, "Expected no compliance flags"
      end

      # =========================================================================
      # SUMMARY STATISTICS
      # =========================================================================

      test "generate_report includes summary statistics" do
        report = generate(immunizations: [ build_imm ], lots: [ build_lot ])

        assert report.summary_statistics.is_a?(Hash)
        assert report.summary_statistics.key?(:total_immunizations)
      end

      # =========================================================================
      # AUDIT EVENT
      # =========================================================================

      test "generate_report creates audit event" do
        count_before = AuditEvent.count
        generate(immunizations: [ build_imm ], lots: [ build_lot ])
        assert_equal count_before + 1, AuditEvent.count
      end

      # =========================================================================
      # GATEWAY FAILURE
      # =========================================================================

      test "flags data_fetch_error when patient search fails" do
        patient_searcher = Object.new
        patient_searcher.define_singleton_method(:call) { |*_args| raise StandardError, "Connection refused" }

        report = VfcComplianceAuditService.generate_report(
          date_range: Date.new(2026, 1, 1)..Date.new(2026, 3, 1),
          agent_id: "user-123",
          patient_searcher: patient_searcher
        )

        assert_not report.compliant?
        fetch_errors = report.findings.select { |f| f[:type] == "data_fetch_error" }
        assert fetch_errors.any?
        assert_equal false, report.summary_statistics[:data_complete]
      end

      test "flags data_fetch_error when lot lister fails" do
        lot_lister = Object.new
        lot_lister.define_singleton_method(:call) { |**_args| raise StandardError, "Timeout" }

        report = generate(
          immunizations: [ build_imm ],
          lot_lister_override: lot_lister
        )

        fetch_errors = report.findings.select { |f| f[:type] == "data_fetch_error" }
        assert fetch_errors.any?
        assert_includes fetch_errors.first[:description], "lot data unavailable"
      end

      test "data_complete is true when all gateways succeed" do
        report = generate(immunizations: [ build_imm ], lots: [ build_lot ])

        assert_equal true, report.summary_statistics[:data_complete]
      end

      # =========================================================================
      # FACILITY SCOPING
      # =========================================================================

      test "facility_ien constrains immunization_records by lot facility_ien" do
        fac_imm = build_imm(ien: "1", lot_number: "LOT-FAC1")
        other_imm = build_imm(ien: "2", lot_number: "LOT-OTHER")
        fac_lot = build_lot(lot_number: "LOT-FAC1", facility_ien: "FAC1")
        other_lot = build_lot(lot_number: "LOT-OTHER", facility_ien: "FAC2")

        report = generate(
          immunizations: [ fac_imm, other_imm ],
          lots: [ fac_lot, other_lot ],
          facility_ien: "FAC1"
        )

        lot_numbers = report.immunization_records.map { |r| r[:lot_number] }
        assert_includes lot_numbers, "LOT-FAC1"
        assert_not_includes lot_numbers, "LOT-OTHER"
      end

      test "nil facility_ien includes all immunizations" do
        imm1 = build_imm(ien: "1", lot_number: "LOT-A")
        imm2 = build_imm(ien: "2", lot_number: "LOT-B")

        report = generate(immunizations: [ imm1, imm2 ], lots: [ build_lot ])

        assert_equal 2, report.immunization_records.length
      end

      private

      def build_imm(overrides = {})
        {
          ien: "1", patient_dfn: "100", vaccine_code: "08", vaccine_display: "COVID-19",
          occurrence_date: Date.new(2026, 2, 1), lot_number: "LOT123",
          provider_duz: "101", provider_name: "Dr. Smith", status: "completed",
          vis_edition_date: nil, vis_presentation_date: nil,
          vfc_eligibility_code: nil, funding_source: nil
        }.merge(overrides)
      end

      def build_lot(overrides = {})
        {
          ien: "10", lot_number: "LOT123", vaccine_code: "08", vaccine_display: "COVID-19",
          manufacturer: "Pfizer", funding_source: "VFC", status: "Active",
          expiration_date: Date.new(2027, 6, 30)
        }.merge(overrides)
      end

      def generate(immunizations: [], lots: [], facility_ien: nil, lot_lister_override: nil)
        imm_lister = Object.new
        captured_imms = immunizations
        imm_lister.define_singleton_method(:call) { |_dfn| captured_imms }

        lot_list = lots
        lot_lister = lot_lister_override || begin
          obj = Object.new
          obj.define_singleton_method(:call) { |**_args| lot_list }
          obj
        end

        patient_searcher = Object.new
        patient_searcher.define_singleton_method(:call) { |*_args| [ { dfn: "100", name: "TEST,PATIENT" } ] }

        VfcComplianceAuditService.generate_report(
          date_range: Date.new(2026, 1, 1)..Date.new(2026, 3, 1),
          facility_ien: facility_ien,
          agent_id: "user-123",
          patient_searcher: patient_searcher,
          immunization_lister: imm_lister,
          lot_lister: lot_lister
        )
      end
    end
  end
end
