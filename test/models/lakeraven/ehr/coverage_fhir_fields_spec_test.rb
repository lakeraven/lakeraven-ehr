# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Issue #239 — Coverage FHIR serialization gaps (factory spec, panel round 1).
    class CoverageFhirFieldsSpecTest < ActiveSupport::TestCase
      COVERAGE_R4_TOP_LEVEL = %w[
        resourceType id meta implicitRules language text contained extension modifierExtension
        identifier status type policyHolder subscriber subscriberId beneficiary dependent
        relationship period payor class order network costToBeneficiary subrogation contract
      ].freeze

      COVERAGE_CLASS_SYSTEM = "http://terminology.hl7.org/CodeSystem/coverage-class"
      IDENTIFIER_TYPE_SYSTEM = "http://terminology.hl7.org/CodeSystem/v2-0203"

      SYNTHETIC_MEMBER_ID = "BC-SYNTH-0001"
      SYNTHETIC_SUBSCRIBER_ID = "BC-SUB-9000"
      SYNTHETIC_PLAN_ID = "BC-PLAN-8842"

      # Inverse of Coverage.from_fhir extract_coverage_type case mapping.
      FHIR_TYPE_CODE_FOR = {
        "medicare_a" => "MEDICARE",
        "medicaid" => "MEDICAID",
        "private_insurance" => "HIP",
        "va_benefits" => "VET",
        "workers_comp" => "WCBPOL",
        "auto_insurance" => "AUTOPOL"
      }.freeze

      PRC_STATUS_TO_FHIR = {
        "exhausted" => "cancelled",
        "not_enrolled" => "cancelled",
        "denied" => "cancelled",
        "pending" => "draft"
      }.freeze

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

      test "to_fhir subscriberId prefers subscriber_id and MB identifier carries member_id" do
        cov = Coverage.new(
          patient_dfn: "1",
          coverage_type: "private_insurance",
          payor_name: "Blue Cross",
          subscriber_id: SYNTHETIC_SUBSCRIBER_ID,
          member_id: SYNTHETIC_MEMBER_ID,
          plan_name: "PPO Gold",
          start_date: Date.new(2024, 1, 1),
          status: "active"
        )

        fhir = cov.to_fhir

        assert_equal SYNTHETIC_SUBSCRIBER_ID, fhir[:subscriberId]
        mb_identifier = fhir[:identifier].find do |id|
          coding = id.dig(:type, :coding, 0) || id.dig("type", "coding", 0)
          coding&.dig(:code) == "MB" || coding&.dig("code") == "MB"
        end
        assert mb_identifier, "Expected identifier with type code MB"
        assert_equal SYNTHETIC_MEMBER_ID, mb_identifier[:value] || mb_identifier["value"]
        assert_equal IDENTIFIER_TYPE_SYSTEM,
          mb_identifier.dig(:type, :coding, 0, :system) || mb_identifier.dig("type", "coding", 0, "system")
      end

      test "to_fhir plan class value is plan id or plan name, never member id" do
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
        assert_equal "PPO Gold", plan_class[:value],
          "R4 Coverage.class (plan).value is the plan identifier (here plan_name when plan_id absent)"
        assert_equal "PPO Gold", plan_class[:name]
        refute_equal SYNTHETIC_MEMBER_ID, plan_class[:value],
          "Member id belongs in subscriberId/identifier, not class[type=plan].value"
      end

      test "to_fhir plan class value prefers plan_id over plan_name" do
        cov = Coverage.new(
          patient_dfn: "1",
          coverage_type: "private_insurance",
          payor_name: "Blue Cross",
          plan_id: SYNTHETIC_PLAN_ID,
          plan_name: "PPO Gold",
          member_id: SYNTHETIC_MEMBER_ID,
          start_date: Date.new(2024, 1, 1),
          status: "active"
        )

        fhir = cov.to_fhir
        plan_class = fhir[:class]&.find { |c| c.dig(:type, :coding, 0, :code) == "plan" }

        assert plan_class, "Expected class[type=plan]"
        assert_equal SYNTHETIC_PLAN_ID, plan_class[:value]
        assert_equal "PPO Gold", plan_class[:name]
      end

      test "from_fhir maps subscriberId and MB identifier to distinct attributes" do
        fhir = {
          resourceType: "Coverage",
          beneficiary: { reference: "Patient/1" },
          subscriberId: SYNTHETIC_SUBSCRIBER_ID,
          identifier: [
            {
              type: { coding: [ { system: IDENTIFIER_TYPE_SYSTEM, code: "MB" } ] },
              value: SYNTHETIC_MEMBER_ID
            }
          ],
          class: [
            {
              type: { coding: [ { system: COVERAGE_CLASS_SYSTEM, code: "plan" } ] },
              value: SYNTHETIC_PLAN_ID,
              name: "PPO Gold"
            }
          ]
        }

        cov = Coverage.from_fhir(fhir)

        assert_equal SYNTHETIC_SUBSCRIBER_ID, cov.subscriber_id
        assert_equal SYNTHETIC_MEMBER_ID, cov.member_id
        assert_equal SYNTHETIC_PLAN_ID, cov.plan_id
        assert_equal "PPO Gold", cov.plan_name
      end

      test "from_fhir(to_fhir(c)) round-trips coverage_type subscriber member and plan_id" do
        original = Coverage.new(
          patient_dfn: "1",
          coverage_type: "private_insurance",
          payor_name: "Blue Cross",
          subscriber_id: SYNTHETIC_SUBSCRIBER_ID,
          member_id: SYNTHETIC_MEMBER_ID,
          plan_id: "PPO Gold",
          plan_name: "PPO Gold",
          start_date: Date.new(2024, 1, 1),
          end_date: Date.new(2024, 12, 31),
          status: "active"
        )

        fhir = original.to_fhir
        type_code = fhir.dig(:type, :coding, 0, :code) || fhir.dig("type", "coding", 0, "code")
        assert_equal FHIR_TYPE_CODE_FOR.fetch(original.coverage_type), type_code,
          "to_fhir must emit Coverage.type coding that from_fhir maps back"

        round_tripped = Coverage.from_fhir(fhir)

        assert round_tripped.valid?, round_tripped.errors.full_messages.join(", ")
        assert_equal original.coverage_type, round_tripped.coverage_type
        assert_equal original.subscriber_id, round_tripped.subscriber_id
        assert_equal original.member_id, round_tripped.member_id
        assert_equal original.plan_id, round_tripped.plan_id
        assert_equal original.plan_name, round_tripped.plan_name
      end

      test "to_fhir class type codings use coverage-class terminology system" do
        cov = Coverage.new(
          patient_dfn: "1",
          coverage_type: "private_insurance",
          group_id: "GRP-1",
          plan_name: "PPO Gold",
          start_date: Date.new(2024, 1, 1),
          status: "active"
        )

        fhir = cov.to_fhir
        fhir.fetch(:class).each do |cls|
          system = cls.dig(:type, :coding, 0, :system)
          assert_equal COVERAGE_CLASS_SYSTEM, system
        end
      end

      test "to_fhir maps PRC-internal statuses to FHIR R4 fm-status while model keeps PRC value" do
        PRC_STATUS_TO_FHIR.each do |prc_status, fhir_status|
          cov = Coverage.new(
            patient_dfn: "1",
            coverage_type: "medicaid",
            status: prc_status,
            start_date: Date.new(2024, 1, 1)
          )

          fhir = cov.to_fhir

          assert_equal fhir_status, fhir[:status],
            "Expected #{prc_status} -> #{fhir_status} on FHIR Coverage.status"
          assert_equal prc_status, cov.status,
            "Model status must remain the PRC-internal value after to_fhir"
        end
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
