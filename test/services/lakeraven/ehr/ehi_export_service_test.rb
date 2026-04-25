# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "csv"

module Lakeraven
  module EHR
    class EhiExportServiceTest < ActiveSupport::TestCase
      setup do
        @_orig_patient = Patient.method(:find_by_dfn)
        @_orig_allergy = AllergyIntolerance.method(:for_patient)
        @_orig_med = MedicationRequest.method(:for_patient)

        stub_patient_data
      end

      teardown do
        Patient.define_singleton_method(:find_by_dfn, @_orig_patient)
        AllergyIntolerance.define_singleton_method(:for_patient, @_orig_allergy)
        MedicationRequest.define_singleton_method(:for_patient, @_orig_med)
      end

      # =============================================================================
      # EXPORT SUCCESS
      # =============================================================================

      test "export returns success" do
        result = export_ehi
        assert result[:success], "Expected successful export: #{result[:errors]}"
      end

      test "export includes files array" do
        result = export_ehi
        assert result[:files].is_a?(Array)
        assert result[:files].any?
      end

      # =============================================================================
      # FHIR RESOURCES
      # =============================================================================

      test "export includes Patient NDJSON" do
        result = export_ehi
        patient_file = result[:files].find { |f| f[:name] =~ /patient/i && f[:type] == "fhir_ndjson" }
        assert patient_file.present?, "Expected Patient NDJSON"
        assert patient_file[:count].positive?
      end

      test "export includes AllergyIntolerance NDJSON" do
        result = export_ehi
        file = result[:files].find { |f| f[:name] == "allergy_intolerance.ndjson" }
        assert file.present?, "Expected AllergyIntolerance NDJSON"
        assert_equal 2, file[:count]
      end

      test "export includes MedicationRequest NDJSON" do
        result = export_ehi
        file = result[:files].find { |f| f[:name] == "medication_request.ndjson" }
        assert file.present?, "Expected MedicationRequest NDJSON"
        assert_equal 1, file[:count]
      end

      test "NDJSON content is valid JSON lines" do
        result = export_ehi
        fhir_files = result[:files].select { |f| f[:type] == "fhir_ndjson" }
        fhir_files.each do |file|
          file[:content].each_line do |line|
            next if line.strip.empty?
            parsed = JSON.parse(line)
            assert parsed.is_a?(Hash), "Expected JSON object in #{file[:name]}"
          end
        end
      end

      # =============================================================================
      # AUDIT LOG
      # =============================================================================

      test "export includes audit log CSV" do
        create_audit_events
        result = export_ehi
        audit_file = result[:files].find { |f| f[:name] =~ /audit.*\.csv/ }
        assert audit_file.present?, "Expected audit log CSV"
      end

      test "audit CSV has headers" do
        create_audit_events
        result = export_ehi
        audit_file = result[:files].find { |f| f[:name] =~ /audit.*\.csv/ }
        rows = CSV.parse(audit_file[:content])
        headers = rows.first
        assert_includes headers, "Timestamp"
        assert_includes headers, "Action"
        assert_includes headers, "Resource Type"
      end

      test "audit CSV includes patient-related events" do
        create_audit_events
        result = export_ehi
        audit_file = result[:files].find { |f| f[:name] =~ /audit.*\.csv/ }
        assert audit_file[:count].positive?
      end

      # =============================================================================
      # CONFIGURATION SUMMARY
      # =============================================================================

      test "export includes configuration summary" do
        result = export_ehi
        config_file = result[:files].find { |f| f[:name] =~ /configuration/ }
        assert config_file.present?, "Expected configuration file"
      end

      test "configuration documents data sources" do
        result = export_ehi
        config_file = result[:files].find { |f| f[:name] =~ /configuration/ }
        assert config_file[:content].include?("data_sources")
      end

      # =============================================================================
      # MANIFEST
      # =============================================================================

      test "export includes manifest.json" do
        result = export_ehi
        manifest = result[:files].find { |f| f[:name] == "manifest.json" }
        assert manifest.present?
      end

      test "manifest lists all files" do
        result = export_ehi
        manifest = result[:files].find { |f| f[:name] == "manifest.json" }
        parsed = JSON.parse(manifest[:content])
        assert parsed["files"].is_a?(Array)
        non_manifest_files = result[:files].reject { |f| f[:name] == "manifest.json" }
        assert_equal non_manifest_files.length, parsed["files"].length
      end

      test "manifest includes export timestamp" do
        result = export_ehi
        manifest = result[:files].find { |f| f[:name] == "manifest.json" }
        parsed = JSON.parse(manifest[:content])
        assert parsed["exported_at"].present?
      end

      test "manifest includes ONC criterion reference" do
        result = export_ehi
        manifest = result[:files].find { |f| f[:name] == "manifest.json" }
        parsed = JSON.parse(manifest[:content])
        assert_match(/170\.315/, parsed["certification_criterion"])
      end

      # =============================================================================
      # EDGE CASES
      # =============================================================================

      test "export with no clinical data still succeeds" do
        AllergyIntolerance.define_singleton_method(:for_patient) { |*_| [] }
        MedicationRequest.define_singleton_method(:for_patient) { |*_, **_| [] }

        result = export_ehi
        assert result[:success]
      end

      test "export for nonexistent patient returns error" do
        Patient.define_singleton_method(:find_by_dfn) { |_| nil }

        result = EhiExportService.new(patient_dfn: "99999").export
        assert_not result[:success]
        assert result[:errors].any?
      end

      # =============================================================================
      # PERFORMANCE
      # =============================================================================

      test "export completes within 10 seconds" do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        export_ehi
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        assert elapsed < 10.0, "EHI export took #{elapsed}s, expected < 10s"
      end

      private

      def export_ehi
        EhiExportService.new(patient_dfn: "12345").export
      end

      def stub_patient_data
        Patient.define_singleton_method(:find_by_dfn) do |dfn|
          Patient.new(dfn: dfn.to_i, name: "Anderson,Alice", sex: "F", dob: 50.years.ago.to_date)
        end

        AllergyIntolerance.define_singleton_method(:for_patient) do |_dfn|
          [
            AllergyIntolerance.new(ien: "allergy-1", patient_dfn: "12345",
              allergen_code: "7980", allergen: "Penicillin", clinical_status: "active"),
            AllergyIntolerance.new(ien: "allergy-2", patient_dfn: "12345",
              allergen_code: "36567", allergen: "Simvastatin", clinical_status: "active")
          ]
        end

        MedicationRequest.define_singleton_method(:for_patient) do |_dfn, **_opts|
          [
            MedicationRequest.new(ien: "med-1", patient_dfn: "12345",
              medication_code: "197884", medication_display: "Lisinopril 10 MG",
              status: "active", intent: "order")
          ]
        end
      end

      def create_audit_events
        AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          agent_who_type: "Practitioner", agent_who_identifier: "789",
          entity_type: "Patient", entity_identifier: "12345"
        )
      end
    end
  end
end
