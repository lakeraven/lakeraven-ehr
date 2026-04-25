# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class ServiceRequestTest < ActiveSupport::TestCase
      # =========================================================================
      # VALIDATION TESTS (ported from rpms_redux)
      # =========================================================================

      def valid_sr_attributes
        { patient_dfn: 100, requesting_provider_ien: 101, service_requested: "Cardiology consult" }
      end

      test "valid with all required attributes" do
        sr = ServiceRequest.new(valid_sr_attributes)
        assert sr.valid?, "ServiceRequest should be valid: #{sr.errors.full_messages}"
      end

      test "requires patient_dfn" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(patient_dfn: nil))
        refute sr.valid?
        assert_includes sr.errors[:patient_dfn], "can't be blank"
      end

      test "requires patient_dfn greater than 0" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(patient_dfn: 0))
        refute sr.valid?
        assert sr.errors[:patient_dfn].any? { |e| e.include?("greater than") }
      end

      test "requires requesting_provider_ien" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(requesting_provider_ien: nil))
        refute sr.valid?
        assert_includes sr.errors[:requesting_provider_ien], "can't be blank"
      end

      test "requires requesting_provider_ien greater than 0" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(requesting_provider_ien: 0))
        refute sr.valid?
        assert sr.errors[:requesting_provider_ien].any? { |e| e.include?("greater than") }
      end

      test "requires service_requested" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(service_requested: nil))
        refute sr.valid?
        assert_includes sr.errors[:service_requested], "can't be blank"
      end

      test "validates status inclusion" do
        %w[active completed cancelled draft].each do |status|
          sr = ServiceRequest.new(valid_sr_attributes.merge(status: status))
          assert sr.valid?, "Status '#{status}' should be valid: #{sr.errors.full_messages}"
        end

        sr = ServiceRequest.new(valid_sr_attributes.merge(status: "bogus"))
        refute sr.valid?
      end

      test "validates urgency inclusion" do
        %w[ROUTINE URGENT EMERGENT].each do |urgency|
          sr = ServiceRequest.new(valid_sr_attributes.merge(urgency: urgency))
          assert sr.valid?, "Urgency '#{urgency}' should be valid: #{sr.errors.full_messages}"
        end

        sr = ServiceRequest.new(valid_sr_attributes.merge(urgency: "SUPER_FAST"))
        refute sr.valid?
      end

      test "allows nil status" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(status: nil))
        assert sr.valid?
      end

      test "allows nil urgency" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(urgency: nil))
        assert sr.valid?
      end

      # =========================================================================
      # PERSISTENCE TESTS (ported from rpms_redux)
      # =========================================================================

      test "persisted? true when ien is set" do
        sr = ServiceRequest.new(ien: 1001)
        assert sr.persisted?
      end

      test "persisted? false when ien is nil" do
        sr = ServiceRequest.new(ien: nil)
        refute sr.persisted?
      end

      test "persisted? false when ien is 0" do
        sr = ServiceRequest.new(ien: 0)
        refute sr.persisted?
      end

      # =========================================================================
      # STATUS PREDICATE TESTS (ported from rpms_redux)
      # =========================================================================

      test "pending? when status is draft" do
        assert ServiceRequest.new(status: "draft").pending?
      end

      test "pending? false when active" do
        refute ServiceRequest.new(status: "active").pending?
      end

      test "active? when status is active" do
        assert ServiceRequest.new(status: "active").active?
      end

      test "completed? when status is completed" do
        assert ServiceRequest.new(status: "completed").completed?
      end

      test "cancelled? when status is cancelled" do
        assert ServiceRequest.new(status: "cancelled").cancelled?
      end

      # =========================================================================
      # BUSINESS LOGIC TESTS (ported from rpms_redux)
      # =========================================================================

      test "priority returns 1 for emergent" do
        sr = ServiceRequest.new(urgency: "EMERGENT")
        assert_equal 1, sr.priority
      end

      test "priority returns 2 for urgent" do
        sr = ServiceRequest.new(urgency: "URGENT")
        assert_equal 2, sr.priority
      end

      test "priority returns 3 for routine" do
        sr = ServiceRequest.new(urgency: "ROUTINE")
        assert_equal 3, sr.priority
      end

      test "priority returns 3 for nil urgency" do
        sr = ServiceRequest.new(urgency: nil)
        assert_equal 3, sr.priority
      end

      test "overdue? when appointment is past and not completed" do
        sr = ServiceRequest.new(appointment_on: Date.current - 1, status: "active")
        assert sr.overdue?
      end

      test "overdue? false when no appointment" do
        sr = ServiceRequest.new(status: "active")
        refute sr.overdue?
      end

      test "overdue? false when completed" do
        sr = ServiceRequest.new(appointment_on: Date.current - 1, status: "completed")
        refute sr.overdue?
      end

      test "overdue? false when cancelled" do
        sr = ServiceRequest.new(appointment_on: Date.current - 1, status: "cancelled")
        refute sr.overdue?
      end

      test "overdue? false when appointment is in future" do
        sr = ServiceRequest.new(appointment_on: Date.current + 1, status: "active")
        refute sr.overdue?
      end

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
      # FHIR MAPPING TESTS (ported from rpms_redux)
      # =========================================================================

      test "map_status_to_fhir returns active for draft" do
        sr = ServiceRequest.new(status: "draft")
        assert_equal "active", sr.send(:map_status_to_fhir)
      end

      test "map_status_to_fhir returns active for active" do
        sr = ServiceRequest.new(status: "active")
        assert_equal "active", sr.send(:map_status_to_fhir)
      end

      test "map_status_to_fhir returns completed for completed" do
        sr = ServiceRequest.new(status: "completed")
        assert_equal "completed", sr.send(:map_status_to_fhir)
      end

      test "map_status_to_fhir returns cancelled for cancelled" do
        sr = ServiceRequest.new(status: "cancelled")
        assert_equal "cancelled", sr.send(:map_status_to_fhir)
      end

      test "map_urgency_to_fhir_priority returns urgent for emergent" do
        sr = ServiceRequest.new(urgency: "EMERGENT")
        assert_equal "urgent", sr.send(:map_urgency_to_fhir_priority)
      end

      test "map_urgency_to_fhir_priority returns urgent for urgent" do
        sr = ServiceRequest.new(urgency: "URGENT")
        assert_equal "urgent", sr.send(:map_urgency_to_fhir_priority)
      end

      test "map_urgency_to_fhir_priority returns routine for routine" do
        sr = ServiceRequest.new(urgency: "ROUTINE")
        assert_equal "routine", sr.send(:map_urgency_to_fhir_priority)
      end

      test "resource_class returns ServiceRequest" do
        assert_equal "ServiceRequest", ServiceRequest.resource_class
      end

      test "from_fhir_attributes extracts service and status" do
        fhir = OpenStruct.new(
          code: OpenStruct.new(text: "Cardiology consult"),
          reasonCode: [ OpenStruct.new(text: "Chest pain") ],
          priority: "urgent",
          status: "active"
        )
        attrs = ServiceRequest.from_fhir_attributes(fhir)
        assert_equal "Cardiology consult", attrs[:service_requested]
        assert_equal "Chest pain", attrs[:reason_for_referral]
        assert_equal "URGENT", attrs[:urgency]
        assert_equal "active", attrs[:status]
      end

      test "to_fhir includes intent and priority" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(ien: 42, urgency: "EMERGENT", status: "active"))
        fhir = sr.to_fhir
        assert_equal "order", fhir[:intent]
        assert_equal "urgent", fhir[:priority]
        assert_equal "active", fhir[:status]
      end

      test "to_fhir includes IHS consult identifier" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(ien: 42))
        fhir = sr.to_fhir
        identifiers = fhir[:identifier]
        ihs_id = identifiers.find { |i| i[:system] == "http://ihs.gov/rpms/consult-id" }
        assert ihs_id, "Should have IHS consult identifier"
        assert_equal "42", ihs_id[:value]
      end

      test "to_fhir includes code and reasonCode" do
        sr = ServiceRequest.new(valid_sr_attributes.merge(
          ien: 1, service_requested: "CARDIOLOGY", reason_for_referral: "Chest pain"
        ))
        fhir = sr.to_fhir
        assert_equal "CARDIOLOGY", fhir.dig(:code, :text)
        assert_equal "Chest pain", fhir[:reasonCode].first[:text]
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
