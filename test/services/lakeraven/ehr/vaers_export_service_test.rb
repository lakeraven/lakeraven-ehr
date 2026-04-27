# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class VaersExportServiceTest < ActiveSupport::TestCase
      setup do
        @_orig_find_by_dfn = Patient.method(:find_by_dfn)
        @_orig_find_by_ien = Immunization.method(:find_by_ien)

        @test_patient = Patient.new(
          dfn: 1, name: "PATIENT,TEST", dob: Date.new(1985, 5, 5), sex: "M"
        )
        @test_immunization = Immunization.new(
          ien: "IMM-1",
          patient_dfn: "1",
          vaccine_code: "213",
          vaccine_display: "COVID-19 mRNA",
          occurrence_datetime: Date.new(2025, 1, 15),
          lot_number: "EL9261",
          manufacturer: "Pfizer",
          site: "Left Deltoid",
          route: "IM"
        )
        @adverse_event = "Anaphylaxis within 15 minutes of COVID-19 mRNA vaccination"
        @onset_date = Date.new(2025, 1, 15)

        mock_patient_lookup
        mock_immunization_lookup
      end

      teardown do
        Patient.define_singleton_method(:find_by_dfn, @_orig_find_by_dfn)
        Immunization.define_singleton_method(:find_by_ien, @_orig_find_by_ien)
      end

      # =========================================================================
      # GENERATION
      # =========================================================================

      test "generate returns a VaersReport" do
        result = VaersExportService.generate(
          patient_dfn: "1",
          immunization_ien: "IMM-1",
          reporter_name: "TEST,PROVIDER",
          adverse_event_description: @adverse_event
        )

        assert_kind_of VaersReport, result
      end

      test "generate populates patient demographics from Patient model" do
        result = VaersExportService.generate(
          patient_dfn: "1",
          immunization_ien: "IMM-1",
          reporter_name: "TEST,PROVIDER",
          adverse_event_description: @adverse_event
        )

        assert_equal "PATIENT,TEST", result.patient_name
        assert_equal Date.new(1985, 5, 5), result.patient_dob
      end

      test "generate populates vaccine data from Immunization model" do
        result = VaersExportService.generate(
          patient_dfn: "1",
          immunization_ien: "IMM-1",
          reporter_name: "TEST,PROVIDER",
          adverse_event_description: @adverse_event
        )

        assert_equal "COVID-19 mRNA", result.vaccine_name
      end

      test "generate uses clinician-provided adverse event description" do
        result = VaersExportService.generate(
          patient_dfn: "1",
          immunization_ien: "IMM-1",
          reporter_name: "TEST,PROVIDER",
          adverse_event_description: @adverse_event,
          onset_date: @onset_date
        )

        assert_equal @adverse_event, result.adverse_event
        assert_equal @onset_date, result.onset_date
      end

      # =========================================================================
      # ADVERSE EVENT SOURCING
      # =========================================================================

      test "adverse event comes from clinician input not generic allergy list" do
        result = VaersExportService.generate(
          patient_dfn: "1",
          immunization_ien: "IMM-1",
          reporter_name: "TEST,PROVIDER",
          adverse_event_description: @adverse_event
        )

        assert_equal @adverse_event, result.adverse_event
      end

      # =========================================================================
      # GATEWAY USAGE
      # =========================================================================

      test "calls Patient model for demographics" do
        patient_called = false
        orig = @_orig_find_by_dfn
        Patient.define_singleton_method(:find_by_dfn) do |dfn|
          patient_called = true
          Patient.new(dfn: 1, name: "PATIENT,TEST", dob: Date.new(1985, 5, 5), sex: "M")
        end

        VaersExportService.generate(
          patient_dfn: "1",
          immunization_ien: "IMM-1",
          reporter_name: "TEST,PROVIDER",
          adverse_event_description: @adverse_event
        )

        assert patient_called, "Expected Patient.find_by_dfn to be called"
      end

      test "calls Immunization model for vaccine data" do
        imm_called = false
        Immunization.define_singleton_method(:find_by_ien) do |ien|
          imm_called = true
          Immunization.new(
            ien: "IMM-1", patient_dfn: "1",
            vaccine_code: "213", vaccine_display: "COVID-19 mRNA"
          )
        end

        VaersExportService.generate(
          patient_dfn: "1",
          immunization_ien: "IMM-1",
          reporter_name: "TEST,PROVIDER",
          adverse_event_description: @adverse_event
        )

        assert imm_called, "Expected Immunization.find_by_ien to be called"
      end

      # =========================================================================
      # CSV EXPORT
      # =========================================================================

      test "generate_csv returns CSV string" do
        csv = VaersExportService.generate_csv(
          patient_dfn: "1",
          immunization_ien: "IMM-1",
          reporter_name: "TEST,PROVIDER",
          adverse_event_description: @adverse_event
        )

        assert csv.is_a?(String)
        assert csv.include?("VAERS_ID")
      end

      # =========================================================================
      # STATELESS TRANSFORMER
      # =========================================================================

      test "service creates no database records" do
        counts_before = AuditEvent.count

        VaersExportService.generate(
          patient_dfn: "1",
          immunization_ien: "IMM-1",
          reporter_name: "TEST,PROVIDER",
          adverse_event_description: @adverse_event
        )

        assert_equal counts_before, AuditEvent.count
      end

      private

      def mock_patient_lookup
        test_patient = @test_patient
        Patient.define_singleton_method(:find_by_dfn) do |_dfn|
          test_patient
        end
      end

      def mock_immunization_lookup
        test_immunization = @test_immunization
        Immunization.define_singleton_method(:find_by_ien) do |_ien|
          test_immunization
        end
      end
    end
  end
end
