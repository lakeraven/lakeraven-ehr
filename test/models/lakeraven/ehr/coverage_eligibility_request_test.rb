# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CoverageEligibilityRequestTest < ActiveSupport::TestCase
      test "creates with required attributes" do
        req = CoverageEligibilityRequest.new(
          patient_dfn: "1",
          coverage_type: "medicaid",
          purpose: "benefits"
        )
        assert req.valid?
      end

      test "validates patient_dfn presence" do
        req = CoverageEligibilityRequest.new(coverage_type: "medicaid", purpose: "benefits")
        assert_not req.valid?
        assert_includes req.errors[:patient_dfn], "can't be blank"
      end

      test "validates coverage_type inclusion" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "bogus", purpose: "benefits")
        assert_not req.valid?
      end

      test "validates purpose inclusion" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicaid", purpose: "bogus")
        assert_not req.valid?
      end

      test "defaults purpose to benefits" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicaid")
        assert_equal "benefits", req.purpose
      end

      test "defaults service_date to today" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicaid")
        assert_equal Date.current, req.service_date
      end

      test "accepts service_type_codes" do
        req = CoverageEligibilityRequest.new(
          patient_dfn: "1", coverage_type: "medicaid",
          service_type_codes: %w[30 MH]
        )
        assert_equal %w[30 MH], req.service_type_codes
      end

      # -- FHIR serialization --------------------------------------------------

      test "to_fhir returns CoverageEligibilityRequest resource" do
        req = CoverageEligibilityRequest.new(
          patient_dfn: "1", coverage_type: "medicaid",
          provider_npi: "1234567890", service_date: Date.new(2025, 6, 1)
        )
        fhir = req.to_fhir

        assert_equal "CoverageEligibilityRequest", fhir[:resourceType]
        assert_equal "active", fhir[:status]
        assert_equal "benefits", fhir[:purpose]
        assert_equal "Patient/1", fhir.dig(:patient, :reference)
        assert_equal "2025-06-01", fhir[:servicedDate]
      end

      test "to_fhir includes insurer for Medicare" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicare_a")
        fhir = req.to_fhir
        assert_equal "Organization/CMS", fhir.dig(:insurer, :reference)
        assert_equal "Medicare Part A", fhir.dig(:insurer, :display)
      end

      test "to_fhir includes insurer for Medicaid" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicaid")
        fhir = req.to_fhir
        assert_equal "Organization/StateMedicaid", fhir.dig(:insurer, :reference)
        assert_equal "Medicaid", fhir.dig(:insurer, :display)
      end

      test "to_fhir includes insurer for VA" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "va_benefits")
        fhir = req.to_fhir
        assert_equal "Organization/VA", fhir.dig(:insurer, :reference)
        assert_equal "VA Benefits", fhir.dig(:insurer, :display)
      end

      test "to_fhir includes item category" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicare_b")
        fhir = req.to_fhir
        assert fhir[:item].present?
        assert_equal "medicare_b", fhir[:item].first[:category][:coding].first[:code]
      end

      test "to_fhir includes provider when provider_npi present" do
        req = CoverageEligibilityRequest.new(
          patient_dfn: "1", coverage_type: "medicaid", provider_npi: "1234567890"
        )
        fhir = req.to_fhir
        assert_equal "1234567890", fhir.dig(:provider, :identifier, :value)
      end

      test "generates id if not provided" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicaid")
        assert req.id.present?
        assert_match(/^[0-9a-f-]{36}$/, req.id)
      end

      test "requires coverage_type" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: nil)
        refute req.valid?
        assert req.errors[:coverage_type].any?
      end

      test "accepts all valid coverage types" do
        %w[medicare_a medicare_b medicare_d medicaid private_insurance
           va_benefits workers_comp auto_insurance state_program tribal_program].each do |ct|
          req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: ct)
          assert req.valid?, "Expected #{ct} to be valid"
        end
      end

      test "from_fhir creates request from FHIR hash" do
        fhir_hash = {
          resourceType: "CoverageEligibilityRequest",
          id: "test-123",
          patient: { reference: "Patient/12345" },
          servicedDate: "2024-03-15",
          purpose: [ "benefits" ],
          item: [ { category: { coding: [ { code: "medicare_a" } ] } } ]
        }
        req = CoverageEligibilityRequest.from_fhir(fhir_hash)
        assert_equal "test-123", req.id
        assert_equal "12345", req.patient_dfn
        assert_equal "medicare_a", req.coverage_type
        assert_equal Date.new(2024, 3, 15), req.service_date
      end

      test "from_fhir handles string keys" do
        fhir_hash = {
          "resourceType" => "CoverageEligibilityRequest",
          "id" => "test-456",
          "patient" => { "reference" => "Patient/67890" },
          "item" => [ { "category" => { "coding" => [ { "code" => "medicaid" } ] } } ]
        }
        req = CoverageEligibilityRequest.from_fhir(fhir_hash)
        assert_equal "test-456", req.id
        assert_equal "67890", req.patient_dfn
        assert_equal "medicaid", req.coverage_type
      end
    end
  end
end
