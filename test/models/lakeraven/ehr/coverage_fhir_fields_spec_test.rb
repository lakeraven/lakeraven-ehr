# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Issue #239 — Coverage FHIR serialization gaps (factory spec, panel round 2).
    #
    # Contract:
    # - Coverage.type is exactly one coding in urn:lakeraven:fhir:CodeSystem:coverage-type;
    #   code is the internal coverage_type value; every COVERAGE_TYPES value round-trips.
    # - No v3-ActCode or SOPT on Coverage.type in this issue.
    # - subscriberId is subscriber_id only; member_id is MB identifier only.
    # - PRC statuses map to R4 fm-status on Coverage.status and round-trip via extension
    #   urn:lakeraven:fhir:StructureDefinition/prc-coverage-status.
    class CoverageFhirFieldsSpecTest < ActiveSupport::TestCase
      COVERAGE_R4_TOP_LEVEL = %w[
        resourceType id meta implicitRules language text contained extension modifierExtension
        identifier status type policyHolder subscriber subscriberId beneficiary dependent
        relationship period payor class order network costToBeneficiary subrogation contract
      ].freeze

      COVERAGE_CLASS_SYSTEM = "http://terminology.hl7.org/CodeSystem/coverage-class"
      IDENTIFIER_TYPE_SYSTEM = "http://terminology.hl7.org/CodeSystem/v2-0203"
      COVERAGE_TYPE_SYSTEM = "urn:lakeraven:fhir:CodeSystem:coverage-type"
      PRC_STATUS_EXTENSION_URL = "urn:lakeraven:fhir:StructureDefinition/prc-coverage-status"

      SYNTHETIC_MEMBER_ID = "BC-SYNTH-0001"
      SYNTHETIC_SUBSCRIBER_ID = "BC-SUB-9000"
      SYNTHETIC_PLAN_ID = "BC-PLAN-8842"

      PRC_STATUS_TO_FHIR = {
        "exhausted" => "cancelled",
        "not_enrolled" => "cancelled",
        "denied" => "cancelled",
        "pending" => "draft"
      }.freeze

      test "to_fhir puts member id only on MB identifier not subscriberId" do
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

        assert_nil fhir[:subscriberId]
        mb_identifier = fhir[:identifier]&.find do |id|
          coding = id.dig(:type, :coding, 0)
          coding&.dig(:code) == "MB"
        end
        assert mb_identifier, "Expected identifier with type code MB"
        assert_equal SYNTHETIC_MEMBER_ID, mb_identifier[:value]
      end

      test "to_fhir subscriberId is subscriber_id only and MB identifier carries member_id" do
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

      test "from_fhir round-trip subscriber_id only leaves member_id nil" do
        original = Coverage.new(
          patient_dfn: "1",
          coverage_type: "private_insurance",
          payor_name: "Blue Cross",
          subscriber_id: SYNTHETIC_SUBSCRIBER_ID,
          start_date: Date.new(2024, 1, 1),
          status: "active"
        )

        round_tripped = Coverage.from_fhir(original.to_fhir)

        assert_equal SYNTHETIC_SUBSCRIBER_ID, round_tripped.subscriber_id
        assert_nil round_tripped.member_id
      end

      test "from_fhir round-trip member_id only leaves subscriber_id nil" do
        original = Coverage.new(
          patient_dfn: "1",
          coverage_type: "private_insurance",
          payor_name: "Blue Cross",
          member_id: SYNTHETIC_MEMBER_ID,
          start_date: Date.new(2024, 1, 1),
          status: "active"
        )

        round_tripped = Coverage.from_fhir(original.to_fhir)

        assert_nil round_tripped.subscriber_id
        assert_equal SYNTHETIC_MEMBER_ID, round_tripped.member_id
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
          "Member id belongs in identifier[MB], not class[type=plan].value"
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

      test "to_fhir Coverage.type uses local coverage-type CodeSystem with code equal to coverage_type" do
        cov = Coverage.new(
          patient_dfn: "1",
          coverage_type: "medicare_b",
          start_date: Date.new(2024, 1, 1),
          status: "active"
        )

        fhir = cov.to_fhir
        codings = Array(fhir.dig(:type, :coding))

        assert_equal 1, codings.size
        assert_equal COVERAGE_TYPE_SYSTEM, codings.first[:system]
        assert_equal "medicare_b", codings.first[:code]
        assert codings.first[:display].present?, "Expected display on local coverage type coding"
        refute_equal "http://terminology.hl7.org/CodeSystem/v3-ActCode", codings.first[:system]
      end

      test "every COVERAGE_TYPES value round-trips through to_fhir and from_fhir" do
        Coverage::COVERAGE_TYPES.each do |type|
          original = Coverage.new(
            patient_dfn: "1",
            coverage_type: type,
            payor_name: "Synthetic Payor",
            start_date: Date.new(2024, 1, 1),
            status: "active"
          )

          fhir = original.to_fhir
          coding = fhir.dig(:type, :coding, 0)
          assert_equal COVERAGE_TYPE_SYSTEM, coding[:system], "Expected local type system for #{type}"
          assert_equal type, coding[:code], "Expected type code to match coverage_type for #{type}"

          round_tripped = Coverage.from_fhir(fhir)
          assert_equal type, round_tripped.coverage_type, "Round-trip failed for #{type}"
        end
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

        round_tripped = Coverage.from_fhir(original.to_fhir)

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

      test "to_fhir maps PRC-internal statuses to FHIR R4 fm-status and PRC extension" do
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
          extension = prc_status_extension(fhir)
          assert extension, "Expected PRC status extension for #{prc_status}"
          assert_equal PRC_STATUS_EXTENSION_URL, extension[:url]
          assert_equal prc_status, extension[:valueCode] || extension["valueCode"]
          assert_equal prc_status, cov.status,
            "Model status must remain the PRC-internal value after to_fhir"
        end
      end

      test "from_fhir prefers PRC status extension over fm-status coding" do
        fhir = {
          resourceType: "Coverage",
          status: "cancelled",
          beneficiary: { reference: "Patient/1" },
          type: {
            coding: [
              {
                system: COVERAGE_TYPE_SYSTEM,
                code: "medicaid",
                display: "Medicaid"
              }
            ]
          },
          extension: [
            {
              url: PRC_STATUS_EXTENSION_URL,
              valueCode: "exhausted"
            }
          ]
        }

        cov = Coverage.from_fhir(fhir)

        assert_equal "exhausted", cov.status
      end

      test "PRC status round-trip preserves determine_prc_eligibility authorization reason" do
        original = Coverage.new(
          patient_dfn: "1",
          coverage_type: "medicaid",
          status: "exhausted",
          start_date: Date.new(2024, 1, 1)
        )

        round_tripped = Coverage.from_fhir(original.to_fhir)

        before = CoverageSummaryService.new([ original ]).summarize.authorization_reason
        after = CoverageSummaryService.new([ round_tripped ]).summarize.authorization_reason

        assert_equal before, after
        assert_equal "alternate resources exhausted", after
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

      private

      def prc_status_extension(fhir)
        Array(fhir[:extension] || fhir["extension"]).find do |ext|
          (ext[:url] || ext["url"]) == PRC_STATUS_EXTENSION_URL
        end
      end
    end
  end
end
