# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class MedicationRequestTest < ActiveSupport::TestCase
      test "has medication attributes" do
        mr = MedicationRequest.new(
          ien: "1", patient_dfn: "100",
          medication_code: "11289", medication_display: "warfarin",
          status: "active", dosage_instruction: "Take 5mg daily",
          dose_quantity: "5", route: "oral", frequency: "daily"
        )
        assert_equal "11289", mr.medication_code
        assert_equal "warfarin", mr.medication_display
        assert_equal "5", mr.dose_quantity
        assert_equal "oral", mr.route
        assert_equal "daily", mr.frequency
      end

      test "active? for active status" do
        assert MedicationRequest.new(status: "active").active?
      end

      test "active? false for stopped" do
        refute MedicationRequest.new(status: "stopped").active?
      end

      test "stores authored_on" do
        dt = DateTime.new(2024, 1, 15, 10, 0)
        mr = MedicationRequest.new(authored_on: dt)
        assert_equal dt, mr.authored_on
      end

      test "stores requester_name" do
        mr = MedicationRequest.new(requester_name: "Dr. Smith")
        assert_equal "Dr. Smith", mr.requester_name
      end

      test "for_patient returns array" do
        results = MedicationRequest.for_patient(1)
        assert_kind_of Array, results
      end

      test "to_fhir returns MedicationRequest resource" do
        mr = MedicationRequest.new(ien: "42", patient_dfn: "100", status: "active")
        fhir = mr.to_fhir
        assert_equal "MedicationRequest", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "active", fhir[:status]
      end

      test "to_fhir includes patient reference" do
        mr = MedicationRequest.new(ien: "1", patient_dfn: "100")
        fhir = mr.to_fhir
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes medicationCodeableConcept" do
        mr = MedicationRequest.new(ien: "1", medication_code: "11289", medication_display: "warfarin")
        fhir = mr.to_fhir
        assert_equal "11289", fhir.dig(:medicationCodeableConcept, :coding, 0, :code)
        assert_equal "warfarin", fhir.dig(:medicationCodeableConcept, :text)
      end

      test "to_fhir includes dosageInstruction" do
        mr = MedicationRequest.new(ien: "1", dosage_instruction: "Take 5mg daily")
        fhir = mr.to_fhir
        assert_equal "Take 5mg daily", fhir[:dosageInstruction]&.first&.dig(:text)
      end

      # -- Gateway DI ----------------------------------------------------------

      test "gateway is configurable" do
        assert MedicationRequest.respond_to?(:gateway)
        assert MedicationRequest.respond_to?(:gateway=)
      end

      test "gateway defaults to MedicationRequestGateway" do
        assert_equal MedicationRequestGateway, MedicationRequest.gateway
      end

      test "for_patient delegates to gateway" do
        mock_gw = Object.new
        def mock_gw.for_patient(_dfn)
          [ Lakeraven::EHR::MedicationRequest.new(ien: "99", patient_dfn: "1", medication_display: "MOCK") ]
        end

        original = MedicationRequest.gateway
        begin
          MedicationRequest.gateway = mock_gw
          results = MedicationRequest.for_patient(1)
          assert_equal 1, results.length
          assert_equal "MOCK", results.first.medication_display
        ensure
          MedicationRequest.gateway = original
        end
      end

      # -- validations -----------------------------------------------------------

      test "validates patient_dfn presence" do
        mr = MedicationRequest.new(medication_display: "Lisinopril")
        refute mr.valid?
        assert_includes mr.errors[:patient_dfn], "can't be blank"
      end

      test "validates medication_display presence" do
        mr = MedicationRequest.new(patient_dfn: "123")
        refute mr.valid?
        assert_includes mr.errors[:medication_display], "can't be blank"
      end

      test "validates status values" do
        mr = MedicationRequest.new(patient_dfn: "123", medication_display: "Lisinopril", status: "invalid")
        refute mr.valid?
        assert_includes mr.errors[:status], "is not included in the list"
      end

      test "allows valid status values" do
        %w[active on-hold cancelled completed stopped draft entered-in-error].each do |status|
          mr = MedicationRequest.new(patient_dfn: "123", medication_display: "Lisinopril", status: status)
          assert mr.valid?, "Expected #{status} to be valid"
        end
      end

      test "validates intent values" do
        mr = MedicationRequest.new(patient_dfn: "123", medication_display: "Lisinopril", intent: "invalid")
        refute mr.valid?
        assert_includes mr.errors[:intent], "is not included in the list"
      end

      # -- resource_class --------------------------------------------------------

      test "resource_class returns MedicationRequest" do
        assert_equal "MedicationRequest", MedicationRequest.resource_class
      end

      # -- persisted? ------------------------------------------------------------

      test "persisted? true when ien present" do
        mr = MedicationRequest.new(ien: "123", patient_dfn: "456", medication_display: "Test")
        assert mr.persisted?
      end

      test "persisted? false when ien blank" do
        mr = MedicationRequest.new(patient_dfn: "456", medication_display: "Test")
        refute mr.persisted?
      end

      # -- to_fhir includes RxNorm system ----------------------------------------

      test "to_fhir includes RxNorm code system" do
        mr = MedicationRequest.new(ien: "1", medication_code: "29046", medication_display: "Lisinopril 10mg")
        fhir = mr.to_fhir
        coding = fhir.dig(:medicationCodeableConcept, :coding, 0)
        assert coding[:system]&.include?("rxnorm")
      end

      # -- to_fhir includes intent -----------------------------------------------

      test "to_fhir includes intent" do
        mr = MedicationRequest.new(ien: "1", patient_dfn: "100", medication_display: "Lisinopril", intent: "order")
        fhir = mr.to_fhir
        assert_equal "order", fhir[:intent]
      end

      # -- to_fhir includes dosage with route and timing -------------------------

      test "to_fhir includes dosage with route and timing" do
        mr = MedicationRequest.new(
          ien: "1", patient_dfn: "100", medication_display: "Lisinopril",
          dosage_instruction: "Take 1 tablet by mouth daily",
          route: "oral", frequency: "QD"
        )
        fhir = mr.to_fhir
        instruction = fhir[:dosageInstruction]&.first
        assert_equal "Take 1 tablet by mouth daily", instruction[:text]
        assert_equal "oral", instruction.dig(:route, :text)
        assert_equal "QD", instruction.dig(:timing, :code, :text)
      end

      # -- to_fhir includes dispense request -------------------------------------

      test "to_fhir includes dispense request" do
        mr = MedicationRequest.new(
          ien: "1", patient_dfn: "100", medication_display: "Lisinopril",
          dispense_quantity: 30, refills: 3, days_supply: 30
        )
        fhir = mr.to_fhir
        dr = fhir[:dispenseRequest]
        assert_equal 3, dr[:numberOfRepeatsAllowed]
        assert_equal 30, dr.dig(:quantity, :value)
        assert_equal 30, dr.dig(:expectedSupplyDuration, :value)
        assert_equal "days", dr.dig(:expectedSupplyDuration, :unit)
      end

      # -- to_fhir includes requester reference ----------------------------------

      test "to_fhir includes requester reference" do
        mr = MedicationRequest.new(
          ien: "1", patient_dfn: "100", medication_display: "Lisinopril",
          requester_duz: "789", requester_name: "Dr. Smith"
        )
        fhir = mr.to_fhir
        assert_equal "Practitioner/789", fhir.dig(:requester, :reference)
        assert_equal "Dr. Smith", fhir.dig(:requester, :display)
      end

      # -- from_fhir_attributes --------------------------------------------------

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          medicationCodeableConcept: OpenStruct.new(
            coding: [ OpenStruct.new(code: "29046", display: "Lisinopril 10mg") ],
            text: "Lisinopril 10mg"
          ),
          status: "active",
          intent: "order"
        )

        attrs = MedicationRequest.from_fhir_attributes(fhir_resource)
        assert_equal "29046", attrs[:medication_code]
        assert_equal "Lisinopril 10mg", attrs[:medication_display]
        assert_equal "active", attrs[:status]
        assert_equal "order", attrs[:intent]
      end
    end
  end
end
