# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientDataServiceTest < ActiveSupport::TestCase
      setup do
        @dfn = "12345"
        @service = PatientDataService.new(@dfn)
      end

      # =========================================================================
      # PHR AVAILABILITY
      # =========================================================================

      test "phr_available? returns false by default in test" do
        # Without a real PHR backend, should return false
        assert_not @service.phr_available?
      end

      test "phr_available? respects RPMS_PHR_ENABLED=false config" do
        ENV["RPMS_PHR_ENABLED"] = "false"

        service = PatientDataService.new(@dfn)
        assert_not service.phr_available?
      ensure
        ENV.delete("RPMS_PHR_ENABLED")
      end

      # =========================================================================
      # MEDICATIONS - DIRECT FALLBACK
      # =========================================================================

      test "medications uses direct RPC when PHR unavailable" do
        mock_direct_medications

        meds = @service.medications

        assert meds.any?
        assert_equal :direct, @service.data_source
      end

      test "medications returns empty array on error" do
        # Without mocking, direct fetch will error safely
        meds = @service.medications

        assert_equal [], meds
      end

      # =========================================================================
      # LAB RESULTS - DIRECT FALLBACK
      # =========================================================================

      test "lab_results uses direct RPC when PHR unavailable" do
        mock_direct_lab_results

        labs = @service.lab_results

        assert labs.any?
        assert_equal :direct, @service.data_source
      end

      # =========================================================================
      # ALLERGIES - DIRECT FALLBACK
      # =========================================================================

      test "allergies uses direct RPC when PHR unavailable" do
        mock_direct_allergies

        allergies = @service.allergies

        assert allergies.any?
        assert_equal :direct, @service.data_source
        assert_equal "Penicillin", allergies.first[:allergen]
      end

      # =========================================================================
      # HEALTH SUMMARY (PHR ONLY)
      # =========================================================================

      test "health_summary returns nil when PHR unavailable" do
        summary = @service.health_summary

        assert_nil summary
      end

      # =========================================================================
      # CCD DOCUMENTS (PHR ONLY)
      # =========================================================================

      test "ccds returns empty array when PHR unavailable" do
        ccds = @service.ccds

        assert_empty ccds
      end

      # =========================================================================
      # DATA SOURCE TRACKING
      # =========================================================================

      test "data_source is nil initially" do
        assert_nil @service.data_source
      end

      test "data_source is set to direct after direct fetch" do
        mock_direct_medications

        @service.medications

        assert_equal :direct, @service.data_source
      end

      # =========================================================================
      # PHR-FIRST WITH FALLBACK
      # =========================================================================

      test "medications uses PHR when available" do
        mock_phr_available
        mock_phr_component_response(:medications, "Lisinopril 10mg - daily")

        meds = @service.medications

        assert meds.any?
        assert_equal :phr, @service.data_source
      end

      test "medications falls back to direct when PHR returns empty" do
        mock_phr_available
        mock_phr_component_response(:medications, "")
        mock_direct_medications

        meds = @service.medications

        assert meds.any?
        assert_equal :direct, @service.data_source
      end

      test "lab_results uses PHR when available" do
        mock_phr_available
        mock_phr_component_response(:labs, "Glucose: 95 mg/dL")

        labs = @service.lab_results

        assert labs.any?
        assert_equal :phr, @service.data_source
      end

      test "allergies uses PHR when available" do
        mock_phr_available
        mock_phr_component_response(:allergies, "Penicillin - Hives")

        allergies = @service.allergies

        assert allergies.any?
        assert_equal :phr, @service.data_source
        assert_equal "Penicillin", allergies.first[:allergen]
      end

      private

      def mock_phr_available
        @service.define_singleton_method(:check_phr_availability) { true }
        @service.instance_variable_set(:@phr_available, nil) # reset cache
      end

      def mock_phr_component_response(component, content)
        captured_component = component
        captured_content = content
        @service.define_singleton_method(:fetch_via_phr) do |comp|
          if comp == captured_component && captured_content.present?
            @data_source = :phr
            send(:parse_component_content, comp, captured_content)
          else
            nil
          end
        end
      end

      def mock_direct_medications
        @service.define_singleton_method(:fetch_medications_direct) do
          @data_source = :direct
          [ { ien: "1", drug_name: "Metformin 500mg", status: "active" },
           { ien: "2", drug_name: "Lisinopril 10mg", status: "active" } ]
        end
      end

      def mock_direct_lab_results
        @service.define_singleton_method(:fetch_lab_results_direct) do |days: 90|
          @data_source = :direct
          [ { ien: "1", test_name: "Glucose", result: "95", units: "mg/dL" } ]
        end
      end

      def mock_direct_allergies
        @service.define_singleton_method(:fetch_allergies_direct) do
          @data_source = :direct
          [ { allergen: "Penicillin", reaction: "Hives", severity: "Moderate" } ]
        end
      end
    end
  end
end
