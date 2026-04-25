# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientTribalEnrollmentTest < ActiveSupport::TestCase
      def setup
        @patient_with_enrollment = Patient.new(
          dfn: 1,
          name: "Anderson,Alice",
          tribal_enrollment_number: "ANLC-12345",
          tribal_affiliation: "Alaska Native - Anchorage (ANLC)",
          service_area: "Anchorage"
        )

        @patient_without_enrollment = Patient.new(
          dfn: 8,
          name: "Harris,Henry",
          tribal_enrollment_number: nil,
          service_area: "Portland"
        )

        @patient_invalid_enrollment = Patient.new(
          dfn: 7,
          name: "Garcia,George",
          tribal_enrollment_number: "INVALID",
          service_area: "Seattle"
        )
      end

      # =============================================================================
      # TRIBAL ENROLLMENT DETAILS
      # =============================================================================

      test "tribal_enrollment_details returns hash with enrollment information" do
        details = @patient_with_enrollment.tribal_enrollment_details

        assert_not_nil details
        assert_equal "ANLC-12345", details[:enrollment_number]
        assert_equal "Alaska Native - Anchorage (ANLC)", details[:tribe_name]
        assert_equal "ACTIVE", details[:status]
        assert_equal "Anchorage", details[:service_unit]
        assert_equal "ANLC", details[:tribe_code]
      end

      test "tribal_enrollment_details returns nil for unsaved patient" do
        patient = Patient.new(tribal_enrollment_number: "ANLC-12345")
        details = patient.tribal_enrollment_details
        assert_nil details
      end

      # =============================================================================
      # VALIDATE TRIBAL ENROLLMENT
      # =============================================================================

      test "validate_tribal_enrollment returns valid for correct enrollment" do
        result = @patient_with_enrollment.validate_tribal_enrollment

        assert result[:valid]
        assert_equal "ANLC", result[:tribe_code]
        assert_equal "12345", result[:enrollment_number]
        assert_equal "ACTIVE", result[:status]
      end

      test "validate_tribal_enrollment returns invalid for incorrect enrollment" do
        result = @patient_invalid_enrollment.validate_tribal_enrollment

        refute result[:valid]
        assert_equal "INACTIVE", result[:status]
      end

      test "validate_tribal_enrollment returns error for missing enrollment" do
        result = @patient_without_enrollment.validate_tribal_enrollment

        refute result[:valid]
        assert_includes result[:message], "No enrollment number"
      end

      # =============================================================================
      # TRIBAL ENROLLMENT VALID?
      # =============================================================================

      test "tribal_enrollment_valid? returns true for valid enrollment" do
        assert @patient_with_enrollment.tribal_enrollment_valid?
      end

      test "tribal_enrollment_valid? returns false for invalid enrollment" do
        refute @patient_invalid_enrollment.tribal_enrollment_valid?
      end

      test "tribal_enrollment_valid? returns false for missing enrollment" do
        refute @patient_without_enrollment.tribal_enrollment_valid?
      end

      # =============================================================================
      # TRIBAL ENROLLMENT ELIGIBILITY
      # =============================================================================

      test "tribal_enrollment_eligibility returns eligibility status" do
        eligibility = @patient_with_enrollment.tribal_enrollment_eligibility

        assert eligibility[:active]
        assert eligibility[:eligible_for_ihs]
        assert_equal "Anchorage", eligibility[:service_unit]
        assert_equal "BASIC", eligibility[:benefit_package]
      end

      test "tribal_enrollment_eligibility returns ineligible for patient without enrollment" do
        eligibility = @patient_without_enrollment.tribal_enrollment_eligibility

        refute eligibility[:active]
        refute eligibility[:eligible_for_ihs]
      end

      test "tribal_enrollment_eligibility returns default for unsaved patient" do
        patient = Patient.new(tribal_enrollment_number: "ANLC-12345")
        eligibility = patient.tribal_enrollment_eligibility

        refute eligibility[:active]
        refute eligibility[:eligible_for_ihs]
      end

      # =============================================================================
      # ELIGIBLE FOR IHS SERVICES
      # =============================================================================

      test "eligible_for_ihs_services? returns true for valid enrollment" do
        assert @patient_with_enrollment.eligible_for_ihs_services?
      end

      test "eligible_for_ihs_services? returns false for invalid enrollment" do
        refute @patient_invalid_enrollment.eligible_for_ihs_services?
      end

      test "eligible_for_ihs_services? returns false for no enrollment" do
        refute @patient_without_enrollment.eligible_for_ihs_services?
      end

      # =============================================================================
      # ENROLLMENT SERVICE UNIT
      # =============================================================================

      test "enrollment_service_unit returns service unit details" do
        service_unit = @patient_with_enrollment.enrollment_service_unit

        assert_not_nil service_unit
        assert service_unit[:ien] > 0
        assert_equal "Anchorage", service_unit[:name]
        assert_equal "Alaska", service_unit[:region]
      end

      test "enrollment_service_unit returns nil for unsaved patient" do
        patient = Patient.new(tribal_enrollment_number: "ANLC-12345")
        service_unit = patient.enrollment_service_unit
        assert_nil service_unit
      end

      # =============================================================================
      # TRIBE INFORMATION
      # =============================================================================

      test "tribe_information returns tribe details from enrollment number" do
        tribe_info = @patient_with_enrollment.tribe_information

        assert_not_nil tribe_info
        assert_equal "ANLC", tribe_info[:code]
        assert_equal "Alaska Native - Anchorage (ANLC)", tribe_info[:name]
        assert_equal "Anchorage", tribe_info[:service_unit]
        assert_equal "Alaska", tribe_info[:region]
      end

      test "tribe_information extracts tribe code from enrollment number" do
        tribe_info = @patient_with_enrollment.tribe_information
        assert_equal "ANLC", tribe_info[:code]
      end

      test "tribe_information returns nil for missing enrollment" do
        tribe_info = @patient_without_enrollment.tribe_information
        assert_nil tribe_info
      end

      test "tribe_information works for different tribe codes" do
        patient_cn = Patient.new(dfn: 2, tribal_enrollment_number: "CN-67890")
        tribe_info = patient_cn.tribe_information

        assert_equal "CN", tribe_info[:code]
        assert_equal "Cherokee Nation", tribe_info[:name]
      end

      # =============================================================================
      # INTEGRATION TESTS
      # =============================================================================

      test "complete eligibility workflow" do
        assert @patient_with_enrollment.tribal_enrollment_valid?

        details = @patient_with_enrollment.tribal_enrollment_details
        assert_equal "ACTIVE", details[:status]

        assert @patient_with_enrollment.eligible_for_ihs_services?

        service_unit = @patient_with_enrollment.enrollment_service_unit
        assert_equal details[:service_unit], service_unit[:name]

        tribe_info = @patient_with_enrollment.tribe_information
        assert_equal details[:tribe_code], tribe_info[:code]
      end

      test "ineligible patient workflow" do
        refute @patient_without_enrollment.tribal_enrollment_valid?
        refute @patient_without_enrollment.eligible_for_ihs_services?

        eligibility = @patient_without_enrollment.tribal_enrollment_eligibility
        refute eligibility[:active]
        refute eligibility[:eligible_for_ihs]
      end

      test "invalid enrollment patient workflow" do
        refute @patient_invalid_enrollment.tribal_enrollment_valid?

        validation = @patient_invalid_enrollment.validate_tribal_enrollment
        refute validation[:valid]
        assert_equal "INACTIVE", validation[:status]
      end

      # =============================================================================
      # ATTRIBUTE TESTS
      # =============================================================================

      test "tribal_enrollment_number attribute is accessible" do
        patient = Patient.new(tribal_enrollment_number: "ANLC-12345")
        assert_equal "ANLC-12345", patient.tribal_enrollment_number
      end

      test "tribal_affiliation attribute is accessible" do
        patient = Patient.new(tribal_affiliation: "Cherokee Nation")
        assert_equal "Cherokee Nation", patient.tribal_affiliation
      end

      test "service_area attribute is accessible" do
        patient = Patient.new(service_area: "Anchorage")
        assert_equal "Anchorage", patient.service_area
      end

      # =============================================================================
      # EDGE CASES
      # =============================================================================

      test "handles enrollment number with different formats" do
        valid_patients = [
          Patient.new(dfn: 1, tribal_enrollment_number: "ANLC-12345"),
          Patient.new(dfn: 2, tribal_enrollment_number: "CN-67890"),
          Patient.new(dfn: 3, tribal_enrollment_number: "NN-11111")
        ]

        valid_patients.each do |patient|
          assert patient.tribal_enrollment_valid?,
            "Expected #{patient.tribal_enrollment_number} to be valid"
        end
      end

      test "handles missing tribe code in enrollment number" do
        patient = Patient.new(dfn: 1, tribal_enrollment_number: "12345")
        refute patient.tribal_enrollment_valid?
      end

      test "handles empty strings vs nil for enrollment" do
        patient_nil = Patient.new(tribal_enrollment_number: nil)
        patient_empty = Patient.new(tribal_enrollment_number: "")

        refute patient_nil.tribal_enrollment_valid?
        refute patient_empty.tribal_enrollment_valid?
      end
    end
  end
end
