# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ServiceRequestTest < ActiveSupport::TestCase
      # =========================================================================
      # ATTRIBUTE TESTS
      # =========================================================================

      test "has core referral attributes" do
        sr = ServiceRequest.new(
          ien: 1, patient_dfn: 100,
          referral_type: "Specialty",
          requesting_provider_ien: 101,
          performer_name: "Dr. Smith",
          identifier: "SR-2024-001"
        )
        assert_equal 1, sr.ien
        assert_equal 100, sr.patient_dfn
        assert_equal "Specialty", sr.referral_type
        assert_equal 101, sr.requesting_provider_ien
        assert_equal "Dr. Smith", sr.performer_name
        assert_equal "SR-2024-001", sr.identifier
      end

      test "has clinical fields" do
        sr = ServiceRequest.new(
          service_requested: "Cardiology consultation",
          reason_for_referral: "Chest pain evaluation",
          urgency: "EMERGENT",
          status: "active"
        )
        assert_equal "Cardiology consultation", sr.service_requested
        assert_equal "Chest pain evaluation", sr.reason_for_referral
        assert_equal "EMERGENT", sr.urgency
        assert_equal "active", sr.status
      end

      test "has cost and coding fields" do
        sr = ServiceRequest.new(
          estimated_cost: 25_000.0,
          diagnosis_codes: "E11.9",
          procedure_codes: "99213"
        )
        assert_equal 25_000.0, sr.estimated_cost
        assert_equal "E11.9", sr.diagnosis_codes
        assert_equal "99213", sr.procedure_codes
      end

      test "should handle service_requests with minimal data" do
        sr = ServiceRequest.new(
          patient_dfn: 1,
          requesting_provider_ien: 101,
          service_requested: "GENERAL"
        )
        assert_equal 1, sr.patient_dfn
        assert_equal 101, sr.requesting_provider_ien
        assert_equal "GENERAL", sr.service_requested
        assert sr.routine?, "Default urgency should be routine"
      end

      test "should handle very long service names and reasons" do
        long_service = "A" * 200
        long_reason = "B" * 500

        sr = ServiceRequest.new(
          service_requested: long_service,
          reason_for_referral: long_reason
        )
        assert_equal long_service, sr.service_requested
        assert_equal long_reason, sr.reason_for_referral
      end

      # =========================================================================
      # URGENCY PREDICATE TESTS
      # =========================================================================

      test "emergent? for EMERGENT urgency" do
        assert ServiceRequest.new(urgency: "EMERGENT").emergent?
      end

      test "emergent? false for ROUTINE" do
        refute ServiceRequest.new(urgency: "ROUTINE").emergent?
      end

      test "emergent? false for URGENT" do
        refute ServiceRequest.new(urgency: "URGENT").emergent?
      end

      test "emergent? false for nil" do
        refute ServiceRequest.new(urgency: nil).emergent?
      end

      test "urgent? for URGENT urgency" do
        assert ServiceRequest.new(urgency: "URGENT").urgent?
      end

      test "urgent? false for ROUTINE" do
        refute ServiceRequest.new(urgency: "ROUTINE").urgent?
      end

      test "urgent? false for EMERGENT" do
        refute ServiceRequest.new(urgency: "EMERGENT").urgent?
      end

      test "urgent? false for nil" do
        refute ServiceRequest.new(urgency: nil).urgent?
      end

      test "routine? for ROUTINE urgency" do
        assert ServiceRequest.new(urgency: "ROUTINE").routine?
      end

      test "routine? true when urgency nil" do
        assert ServiceRequest.new(urgency: nil).routine?
      end

      test "routine? true when urgency blank" do
        assert ServiceRequest.new(urgency: "").routine?
      end

      test "routine? false for EMERGENT" do
        refute ServiceRequest.new(urgency: "EMERGENT").routine?
      end

      test "routine? false for URGENT" do
        refute ServiceRequest.new(urgency: "URGENT").routine?
      end

      # =========================================================================
      # FHIR SERIALIZATION TESTS
      # =========================================================================

      test "to_fhir returns ServiceRequest resource" do
        sr = ServiceRequest.new(ien: 42, patient_dfn: 100)
        fhir = sr.to_fhir
        assert_equal "ServiceRequest", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes status" do
        sr = ServiceRequest.new(ien: 1, status: "active")
        fhir = sr.to_fhir
        assert_equal "active", fhir[:status]
      end

      test "to_fhir omits subject when no patient_dfn" do
        sr = ServiceRequest.new(ien: 1)
        fhir = sr.to_fhir
        assert_nil fhir[:subject]
      end

      test "to_fhir with completed status" do
        sr = ServiceRequest.new(ien: 1, status: "completed")
        fhir = sr.to_fhir
        assert_equal "completed", fhir[:status]
      end

      test "to_fhir with cancelled status" do
        sr = ServiceRequest.new(ien: 1, status: "cancelled")
        fhir = sr.to_fhir
        assert_equal "cancelled", fhir[:status]
      end

      test "to_fhir with nil ien" do
        sr = ServiceRequest.new(patient_dfn: 100)
        fhir = sr.to_fhir
        assert_equal "ServiceRequest", fhir[:resourceType]
        assert_nil fhir[:id]
      end

      # =========================================================================
      # CLASS METHOD TESTS
      # =========================================================================

      test "for_patient returns array" do
        results = ServiceRequest.for_patient(1)
        assert_kind_of Array, results
      end

      test "for_patient returns empty array for unknown patient" do
        results = ServiceRequest.for_patient(999)
        assert_kind_of Array, results
        assert_equal 0, results.length
      end
    end
  end
end
