# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Issue #239 — Coverage FHIR serialization gaps (factory spec).
    class CoverageFhirFieldsSpecTest < ActiveSupport::TestCase
      COVERAGE_R4_TOP_LEVEL = %w[
        resourceType id meta implicitRules language text contained extension modifierExtension
        identifier status type policyHolder subscriber subscriberId beneficiary dependent
        relationship period payor class order network costToBeneficiary subrogation contract
      ].freeze

      SYNTHETIC_MEMBER_ID = "BC-SYNTH-0001"

      test "to_fhir exposes member id as subscriberId and identifier" do
        cov = Coverage.new(
          patient_dfn: "1",
          coverage_type: "private_insurance",
          payor_name: "Blue Cross",
          plan_name: "PPO Gold",
          member_id: SYNTHETIC_MEMBER_ID,
          start_date: Date.new(2024, 1, 1),
          status: "active"
        )

        fhir = cov.to_fhir

        assert_equal SYNTHETIC_MEMBER_ID, fhir[:subscriberId]
        assert fhir[:identifier].present?, "Expected FHIR Coverage.identifier for member id"
        assert fhir[:identifier].any? { |id| (id[:value] || id["value"]) == SYNTHETIC_MEMBER_ID }
      end

      test "to_fhir plan class carries member id as value and plan name as name" do
        cov = Coverage.new(
          patient_dfn: "1",
          coverage_type: "private_insurance",
          payor_name: "Blue Cross",
          plan_name: "PPO Gold",
          member_id: SYNTHETIC_MEMBER_ID,
          start_date: Date.new(2024, 1, 1),
          status: "active"
        )

        fhir = cov.to_fhir
        plan_class = fhir[:class]&.find { |c| c.dig(:type, :coding, 0, :code) == "plan" }

        assert plan_class, "Expected class[type=plan]"
        assert_equal SYNTHETIC_MEMBER_ID, plan_class[:value]
        assert_equal "PPO Gold", plan_class[:name]
      end

      test "to_fhir satisfies FHIR R4 Coverage required elements and element names" do
        cov = Coverage.new(
          patient_dfn: "1",
          coverage_type: "private_insurance",
          payor_name: "Blue Cross",
          plan_name: "PPO Gold",
          member_id: SYNTHETIC_MEMBER_ID,
          start_date: Date.new(2024, 1, 1),
          status: "active"
        )

        fhir = cov.to_fhir

        assert_equal "Coverage", fhir[:resourceType]
        assert fhir[:status].present?, "FHIR Coverage.status is required"
        assert fhir.dig(:beneficiary, :reference).present?, "FHIR Coverage.beneficiary is required"
        assert fhir[:payor].present?, "FHIR Coverage.payor is required"

        fhir.each_key do |key|
          assert_includes COVERAGE_R4_TOP_LEVEL, key.to_s,
            "Unexpected top-level key on Coverage: #{key}"
        end
      end

      test "from_eligibility_response for Medicaid enrollment sets payor Medicaid and coverage type" do
        response = CoverageEligibilityResponse.new(
          patient_dfn: "12345",
          coverage_type: "medicaid",
          status: "enrolled",
          plan_name: "State Medicaid",
          insurer_name: "State Medicaid Agency",
          start_date: Date.new(2024, 1, 1),
          end_date: Date.new(2024, 12, 31)
        )

        cov = Coverage.from_eligibility_response(response)

        assert cov.present?
        assert_equal "medicaid", cov.coverage_type
        assert_equal "Medicaid", cov.payor_name
        assert_equal "Medicaid", cov.payor_display
      end
    end
  end
end
