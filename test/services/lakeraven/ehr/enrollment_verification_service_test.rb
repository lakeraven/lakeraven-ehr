# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EnrollmentVerificationServiceTest < ActiveSupport::TestCase
      setup do
        @patient = Patient.new(
          dfn: 1,
          name: "TEST,PATIENT",
          sex: "M",
          tribal_enrollment_number: "ANLC-12345",
          service_area: "Anchorage"
        )
      end

      # =========================================================================
      # INITIALIZATION
      # =========================================================================

      test "initializes with patient object" do
        service = EnrollmentVerificationService.new(@patient)

        assert_equal @patient.dfn.to_s, service.patient_dfn
        assert_equal @patient, service.patient
      end

      test "initializes with patient DFN" do
        service = EnrollmentVerificationService.new("12345")

        assert_equal "12345", service.patient_dfn
      end

      # =========================================================================
      # VERIFY SINGLE RESOURCE
      # =========================================================================

      test "verify returns VerificationResult for tribal_program" do
        service = build_mock_service(@patient)
        result = service.verify(:tribal_program)

        assert_instance_of EnrollmentVerificationService::VerificationResult, result
        assert_equal "tribal_program", result.resource_type
        assert result.success?
      end

      test "verify handles unknown resource type gracefully" do
        service = build_mock_service(@patient)
        result = service.verify(:unknown_type)

        assert_instance_of EnrollmentVerificationService::VerificationResult, result
        assert result.success?
      end

      test "verify returns VerificationResult for medicare" do
        service = build_mock_service(@patient)
        result = service.verify(:medicare_a)

        assert_instance_of EnrollmentVerificationService::VerificationResult, result
        assert_equal "medicare_a", result.resource_type
        assert result.success?
        assert_includes [ true, false ], result.enrolled
      end

      test "verify returns VerificationResult for medicaid" do
        service = build_mock_service(@patient)
        result = service.verify(:medicaid)

        assert_instance_of EnrollmentVerificationService::VerificationResult, result
        assert_equal "medicaid", result.resource_type
        assert result.success?
      end

      # =========================================================================
      # VERIFY ALL
      # =========================================================================

      test "verify_all returns results for all resource types" do
        service = build_mock_service(@patient)
        results = service.verify_all

        assert results.is_a?(Array)
        results.each do |result|
          assert_instance_of EnrollmentVerificationService::VerificationResult, result
        end
      end

      # =========================================================================
      # VERIFICATION RESULT
      # =========================================================================

      test "VerificationResult success? returns true when no error" do
        result = EnrollmentVerificationService::VerificationResult.new(
          resource_type: "medicare_a",
          status: :enrolled,
          enrolled: true
        )

        assert result.success?
      end

      test "VerificationResult success? returns false when error present" do
        result = EnrollmentVerificationService::VerificationResult.new(
          resource_type: "medicare_a",
          status: :not_checked,
          error: "Connection failed"
        )

        assert_not result.success?
      end

      test "VerificationResult enrolled? returns true when enrolled" do
        result = EnrollmentVerificationService::VerificationResult.new(
          resource_type: "medicare_a",
          enrolled: true
        )

        assert result.enrolled?
      end

      test "VerificationResult enrolled? returns false when not enrolled" do
        result = EnrollmentVerificationService::VerificationResult.new(
          resource_type: "medicare_a",
          enrolled: false
        )

        assert_not result.enrolled?
      end

      # =========================================================================
      # ERROR HANDLING
      # =========================================================================

      test "verify captures adapter errors gracefully" do
        service = EnrollmentVerificationService.new(@patient)
        # Override medicare adapter to raise
        service.define_singleton_method(:medicare_adapter) do |_resource_type|
          raise StandardError, "Network error"
        end

        result = service.verify(:medicare_a)

        assert_instance_of EnrollmentVerificationService::VerificationResult, result
        assert_not result.success?
        assert result.error.present?
      end

      # =========================================================================
      # TRIBAL ADAPTER
      # =========================================================================

      test "tribal adapter detects enrollment from patient" do
        service = EnrollmentVerificationService.new(@patient)
        result = service.send(:tribal_adapter, "tribal_program")

        assert_instance_of EnrollmentVerificationService::VerificationResult, result
        assert result.enrolled?
        assert_equal "ANLC-12345", result.policy_number
      end

      test "tribal adapter detects no enrollment when missing" do
        patient = Patient.new(dfn: 2, name: "TEST,OTHER", sex: "F", tribal_enrollment_number: nil)
        service = EnrollmentVerificationService.new(patient)
        result = service.send(:tribal_adapter, "tribal_program")

        assert_not result.enrolled?
      end

      # =========================================================================
      # GENERIC ADAPTER
      # =========================================================================

      test "generic adapter returns not_checked" do
        service = EnrollmentVerificationService.new(@patient)
        result = service.send(:generic_adapter, "workers_comp")

        assert result.success?
        assert_equal :not_checked, result.status
        assert_nil result.enrolled
      end

      private

      def build_mock_service(patient)
        service = EnrollmentVerificationService.new(patient)

        service.define_singleton_method(:medicare_adapter) do |resource_type|
          EnrollmentVerificationService::VerificationResult.new(
            resource_type: resource_type,
            status: :enrolled,
            enrolled: true,
            payer_name: "Medicare Part A",
            response_data: { "source" => "mock" }
          )
        end

        service.define_singleton_method(:medicaid_adapter) do |resource_type|
          EnrollmentVerificationService::VerificationResult.new(
            resource_type: resource_type,
            status: :not_enrolled,
            enrolled: false,
            response_data: { "source" => "mock" }
          )
        end

        service.define_singleton_method(:va_adapter) do |resource_type|
          EnrollmentVerificationService::VerificationResult.new(
            resource_type: resource_type,
            status: :not_checked,
            enrolled: nil,
            response_data: { "source" => "mock" }
          )
        end

        service.define_singleton_method(:private_insurance_adapter) do |resource_type|
          EnrollmentVerificationService::VerificationResult.new(
            resource_type: resource_type,
            status: :not_checked,
            enrolled: nil,
            response_data: { "source" => "mock" }
          )
        end

        service
      end
    end
  end
end
