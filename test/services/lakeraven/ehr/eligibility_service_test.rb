# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EligibilityServiceTest < ActiveSupport::TestCase
      # =========================================================================
      # TRIBAL ENROLLMENT CHECKS
      # =========================================================================

      test "tribal enrollment check passes with valid enrollment number" do
        patient = build_patient(tribal_enrollment_number: "ANLC-12345")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:tribal_enrollment)
        assert result.check_message(:tribal_enrollment).include?("Valid tribal enrollment")
        assert result.check_message(:tribal_enrollment).include?("ANLC-12345")
      end

      test "tribal enrollment check fails with invalid format" do
        patient = build_patient(tribal_enrollment_number: "12345")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "FAIL", result.check_status(:tribal_enrollment)
        assert result.check_message(:tribal_enrollment).include?("Invalid or missing")
      end

      test "tribal enrollment check fails when missing" do
        patient = build_patient(tribal_enrollment_number: nil)
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "FAIL", result.check_status(:tribal_enrollment)
        assert result.check_message(:tribal_enrollment).include?("Invalid or missing")
      end

      # =========================================================================
      # RESIDENCY/SERVICE AREA CHECKS
      # =========================================================================

      test "residency check passes for Anchorage service area" do
        patient = build_patient(service_area: "Anchorage")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:residency)
        assert result.check_message(:residency).include?("Anchorage")
      end

      test "residency check passes for Fairbanks service area" do
        patient = build_patient(service_area: "Fairbanks")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:residency)
        assert result.check_message(:residency).include?("Fairbanks")
      end

      test "residency check passes for Bethel service area" do
        patient = build_patient(service_area: "Bethel")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:residency)
        assert result.check_message(:residency).include?("Bethel")
      end

      test "residency check fails for invalid service area" do
        patient = build_patient(service_area: "Seattle")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "FAIL", result.check_status(:residency)
        assert result.check_message(:residency).include?("outside coverage region")
        assert result.check_message(:residency).include?("Seattle")
      end

      test "residency check fails when service area is nil" do
        patient = build_patient(service_area: nil)
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "FAIL", result.check_status(:residency)
      end

      # =========================================================================
      # CLINICAL NECESSITY CHECKS
      # =========================================================================

      test "clinical necessity passes for urgent chest pain service request" do
        sr = build_sr(
          reason_for_referral: "Chest pain with cardiac risk factors",
          urgency: "URGENT",
          service_requested: "Cardiology consultation"
        )

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:clinical_necessity)
        assert result.check_message(:clinical_necessity).include?("URGENT service request")
      end

      test "clinical necessity passes for emergent cardiac condition" do
        sr = build_sr(
          reason_for_referral: "Severe chest pain, suspected MI",
          urgency: "EMERGENT",
          service_requested: "Emergency Cardiology"
        )

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:clinical_necessity)
      end

      test "clinical necessity passes for routine chronic condition" do
        sr = build_sr(
          reason_for_referral: "Chronic joint pain requiring orthopedic evaluation",
          urgency: "ROUTINE",
          service_requested: "Orthopedic consultation"
        )

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:clinical_necessity)
      end

      test "clinical necessity fails when reason missing" do
        sr = build_sr(reason_for_referral: "", urgency: "ROUTINE")

        result = EligibilityService.check(sr)

        assert_equal "FAIL", result.check_status(:clinical_necessity)
        assert result.check_message(:clinical_necessity).include?("Clinical reason for service request is required")
      end

      test "clinical necessity fails for insufficient justification" do
        sr = build_sr(
          reason_for_referral: "Patient wants to see specialist",
          urgency: "ROUTINE"
        )

        result = EligibilityService.check(sr)

        assert_equal "FAIL", result.check_status(:clinical_necessity)
        assert result.check_message(:clinical_necessity).include?("Insufficient clinical justification")
      end

      test "clinical necessity fails when urgency does not match presentation" do
        sr = build_sr(
          reason_for_referral: "Chronic mild headache",
          urgency: "EMERGENT"
        )

        result = EligibilityService.check(sr)

        assert_equal "FAIL", result.check_status(:clinical_necessity)
        assert result.check_message(:clinical_necessity).include?("Urgency level does not match")
      end

      # =========================================================================
      # PAYOR COORDINATION CHECKS
      # =========================================================================

      test "payor coordination passes for IHS only coverage" do
        patient = build_patient(coverage_type: "IHS")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:payor_coordination)
        assert result.check_message(:payor_coordination).include?("IHS is primary payor")
      end

      test "payor coordination passes for Medicare/IHS dual coverage" do
        patient = build_patient(coverage_type: "Medicare/IHS")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:payor_coordination)
        assert result.check_message(:payor_coordination).include?("Medicare is primary")
        assert result.check_message(:payor_coordination).include?("IHS will coordinate as secondary")
      end

      test "payor coordination passes for Private Insurance/IHS" do
        patient = build_patient(coverage_type: "Private Insurance/IHS")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:payor_coordination)
        assert result.check_message(:payor_coordination).include?("Private insurance is primary")
      end

      test "payor coordination passes for Medicaid/IHS" do
        patient = build_patient(coverage_type: "Medicaid/IHS")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "PASS", result.check_status(:payor_coordination)
        assert result.check_message(:payor_coordination).include?("Medicaid is primary")
      end

      test "payor coordination fails for unknown coverage type" do
        patient = build_patient(coverage_type: "Unknown")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "FAIL", result.check_status(:payor_coordination)
        assert result.check_message(:payor_coordination).include?("Unknown or invalid coverage type")
      end

      test "payor coordination fails when coverage type is nil" do
        patient = build_patient(coverage_type: nil)
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        assert_equal "FAIL", result.check_status(:payor_coordination)
      end

      # =========================================================================
      # ELIGIBILITY RESULT TESTS
      # =========================================================================

      test "eligibility result reports eligible when all checks pass" do
        patient = build_patient(
          tribal_enrollment_number: "ANLC-12345",
          service_area: "Anchorage",
          coverage_type: "IHS"
        )
        sr = build_sr(
          patient: patient,
          reason_for_referral: "Chest pain requiring cardiac evaluation",
          urgency: "URGENT"
        )

        result = EligibilityService.check(sr)

        assert result.eligible?, "Expected patient to be eligible"
        assert_nil result.denial_reason
      end

      test "eligibility result reports not eligible when any check fails" do
        patient = build_patient(
          tribal_enrollment_number: "INVALID",
          service_area: "Anchorage",
          coverage_type: "IHS"
        )
        sr = build_sr(
          patient: patient,
          reason_for_referral: "Cardiac evaluation required",
          urgency: "URGENT"
        )

        result = EligibilityService.check(sr)

        assert_not result.eligible?
        assert result.denial_reason.present?
        assert result.denial_reason.include?("Invalid or missing tribal enrollment")
      end

      test "eligibility result combines multiple denial reasons" do
        patient = build_patient(
          tribal_enrollment_number: "INVALID",
          service_area: "Seattle",
          coverage_type: "Unknown"
        )
        sr = build_sr(
          patient: patient,
          reason_for_referral: "Patient wants service request",
          urgency: "ROUTINE"
        )

        result = EligibilityService.check(sr)

        assert_not result.eligible?
        denial = result.denial_reason
        assert denial.include?("tribal enrollment")
        assert denial.include?("outside coverage region")
        assert denial.include?("Unknown or invalid coverage type")
        assert denial.include?("Insufficient clinical justification")
      end

      test "eligibility result provides access to individual check status" do
        sr = build_sr
        result = EligibilityService.check(sr)

        assert result.check_status(:tribal_enrollment).present?
        assert result.check_status(:residency).present?
        assert result.check_status(:clinical_necessity).present?
        assert result.check_status(:payor_coordination).present?
      end

      test "eligibility result provides access to individual check messages" do
        patient = build_patient(tribal_enrollment_number: "ANLC-12345")
        sr = build_sr(patient: patient)

        result = EligibilityService.check(sr)

        message = result.check_message(:tribal_enrollment)
        assert message.present?
        assert message.include?("ANLC-12345")
      end

      # =========================================================================
      # COMPLETE ELIGIBILITY WORKFLOW TESTS
      # =========================================================================

      test "complete eligibility check for CHS-eligible patient" do
        patient = build_patient(
          tribal_enrollment_number: "ANLC-99999",
          service_area: "Anchorage",
          coverage_type: "IHS"
        )
        sr = build_sr(
          patient: patient,
          reason_for_referral: "Specialty cardiac evaluation for chest pain",
          urgency: "URGENT",
          service_requested: "Cardiology consultation"
        )

        result = EligibilityService.check(sr)

        assert result.eligible?
        assert_equal "PASS", result.check_status(:tribal_enrollment)
        assert_equal "PASS", result.check_status(:residency)
        assert_equal "PASS", result.check_status(:clinical_necessity)
        assert_equal "PASS", result.check_status(:payor_coordination)
      end

      test "complete eligibility check for Medicare dual-eligible patient" do
        patient = build_patient(
          tribal_enrollment_number: "ANLC-88888",
          service_area: "Fairbanks",
          coverage_type: "Medicare/IHS"
        )
        sr = build_sr(
          patient: patient,
          reason_for_referral: "Chronic orthopedic condition requiring surgical evaluation",
          urgency: "ROUTINE",
          service_requested: "Orthopedic Surgery"
        )

        result = EligibilityService.check(sr)

        assert result.eligible?
        assert result.check_message(:payor_coordination).include?("Medicare is primary")
      end

      test "eligibility check fails for patient outside service area" do
        patient = build_patient(
          tribal_enrollment_number: "ANLC-77777",
          service_area: "Portland",
          coverage_type: "IHS"
        )
        sr = build_sr(
          patient: patient,
          reason_for_referral: "Cardiac evaluation required",
          urgency: "URGENT"
        )

        result = EligibilityService.check(sr)

        assert_not result.eligible?
        assert_equal "FAIL", result.check_status(:residency)
        assert result.denial_reason.include?("outside coverage region")
      end

      private

      def build_patient(attrs = {})
        defaults = {
          dfn: 1,
          name: "TEST,PATIENT",
          sex: "M",
          tribal_enrollment_number: "ANLC-12345",
          service_area: "Anchorage",
          coverage_type: "IHS"
        }
        Patient.new(defaults.merge(attrs))
      end

      def build_sr(attrs = {})
        patient = attrs.delete(:patient) || build_patient
        defaults = {
          ien: 1,
          patient_dfn: patient.dfn,
          requesting_provider_ien: 101,
          service_requested: "Specialty consultation",
          reason_for_referral: "Clinical evaluation required",
          urgency: "ROUTINE",
          status: "draft"
        }
        sr = ServiceRequest.new(defaults.merge(attrs))
        # Wire up patient association
        sr.define_singleton_method(:patient) { patient }
        sr.define_singleton_method(:urgency_symbol) {
          case urgency
          when "EMERGENT" then :emergent
          when "URGENT" then :urgent
          else :routine
          end
        }
        sr
      end
    end
  end
end
