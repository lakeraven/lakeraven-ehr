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
        %w[active on-hold cancelled completed stopped draft entered-in-error unknown].each do |status|
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

      # Builder: MedicationRequest.from_rpms_row(row, patient_dfn:) — read path maps gateway Hashes to models;
      # for_patient must keep returning those Hashes for the chart, FHIR search and export; CPOE
      # and decision support read checked_for_patient, which maps them (#680).
      test "from_rpms_row maps gateway active-medication row to US Core MedicationRequest serialization" do
        original_client = RpmsRpc.configuration.client
        RpmsRpc.mock! do |m|
          require_relative "../../../dummy/lib/lakeraven_demo_seeds"
          LakeravenDemoSeeds.seed(m)
        end

        row = MedicationRequest.for_patient("1").first
        assert_kind_of Hash, row
        assert_equal "Lisinopril 10mg", row[:name]
        assert_equal "1R;O", row[:order_id]
        assert_equal "ACTIVE", row[:status]

        mr = MedicationRequest.from_rpms_row(row, patient_dfn: "1")
        assert_kind_of MedicationRequest, mr
        assert_equal "1R-O", mr.ien
        assert_equal "1", mr.patient_dfn
        assert_equal "Lisinopril 10mg", mr.medication_display
        assert_equal "active", mr.status
        assert_equal "order", mr.intent

        fhir = mr.to_fhir
        assert_equal "MedicationRequest", fhir[:resourceType]
        assert_equal "1R-O", fhir[:id]
        assert_equal "active", fhir[:status]
        assert_equal "order", fhir[:intent]
        assert_equal "Patient/1", fhir.dig(:subject, :reference)
        assert_equal "Lisinopril 10mg", fhir.dig(:medicationCodeableConcept, :text)
        assert_nil fhir.dig(:medicationCodeableConcept, :coding)
        assert_nil fhir[:authoredOn]
        authored_dar = fhir.dig(:_authoredOn, :extension)&.find do |ext|
          ext[:url] == "http://hl7.org/fhir/StructureDefinition/data-absent-reason"
        end
        assert authored_dar, "expected data-absent-reason on _authoredOn when RPMS has no order date"
        assert_equal "unknown", authored_dar[:valueCode]
        requester = fhir[:requester]
        assert_nil requester&.dig(:reference)
        assert_nil requester&.dig(:display)
        requester_dar = requester&.dig(:extension)&.find do |ext|
          ext[:url] == "http://hl7.org/fhir/StructureDefinition/data-absent-reason"
        end
        assert requester_dar, "expected data-absent-reason on requester when RPMS has no provider"
        assert_equal "unknown", requester_dar[:valueCode]
      ensure
        RpmsRpc.configure { |c| c.client = original_client }
      end

      # One outpatient order on the ORWPS ACTIVE wire, read through the gateway
      # and the rpms-rpc parser: order id, drug, expiration, refills, CPRS order
      # number, status (piece 9 of the OCL node), then its instruction lines.
      def active_medication(status:, stop: "3271231", order_id: "4401R;O", lines: [ "\\ Sig: TAKE 1 TABLET BY MOUTH" ])
        RpmsRpc.client.seed_text(:medication_active, "1",
          [ "~OP^#{order_id}^METFORMIN 500MG TAB^^#{stop}^3^^^120345^#{status}", *lines ].join("\n"))
        row = MedicationRequest.for_patient("1").first
        MedicationRequest.from_rpms_row(row, patient_dfn: "1")
      end

      # The RPMS order statuses and the FHIR status each maps to (#628).
      {
        "ACTIVE" => "active",
        "REFILL FILL" => "active",
        "HOLD" => "on-hold",
        "SUSPENDED" => "on-hold",
        "NON-VERIFIED" => "draft",
        "PENDING" => "draft",
        "EXPIRED" => "completed",
        "DONE" => "completed",
        "DISCONTINUED" => "stopped",
        "DISCONTINUED (EDIT)" => "stopped"
      }.each do |rpms, fhir_status|
        test "from_rpms_row maps RPMS order status #{rpms} to #{fhir_status}" do
          mr = active_medication(status: rpms)
          assert_equal fhir_status, mr.status
          assert_equal fhir_status, mr.to_fhir[:status]
          assert mr.valid?, mr.errors.full_messages.to_sentence
        end
      end

      test "from_rpms_row keeps a discontinued order stopped when its stop date is still in the future" do
        future = RpmsRpc::FilemanDateParser.format_date(Date.current + 365)
        mr = active_medication(status: "DISCONTINUED", stop: future)

        assert_equal "stopped", mr.status
        refute_includes mr.to_fhir.to_json, future
      end

      test "from_rpms_row keeps an ACTIVE order active when its stop date has passed" do
        mr = active_medication(status: "ACTIVE", stop: "3200101")
        assert_equal "active", mr.status
      end

      test "from_rpms_row maps an unrecognised RPMS order status to unknown" do
        assert_equal "unknown", active_medication(status: "SOMETHING NEW").status
      end

      test "from_rpms_row maps an order with no status piece to unknown" do
        mr = active_medication(status: "")
        assert_equal "unknown", mr.status
        refute_equal "active", mr.status
      end

      test "from_rpms_row encodes the RPMS order id as a legal FHIR id that reverses" do
        mr = active_medication(status: "ACTIVE", order_id: "403R;O")

        assert_equal "403R-O", mr.ien
        assert_match(/\A[A-Za-z0-9\-.]{1,64}\z/, mr.to_fhir[:id])
        assert_equal "403R;O", mr.ien.tr("-", ";")
      end

      test "from_rpms_row takes dosageInstruction text from the order's instruction lines" do
        mr = active_medication(status: "ACTIVE", lines: [
          " METFORMIN 500MG TAB  Qty: 30 for 30 days",
          "\\ Sig: TAKE 1 TABLET BY MOUTH",
          " DAILY WITH BREAKFAST"
        ])

        expected = "METFORMIN 500MG TAB  Qty: 30 for 30 days Sig: TAKE 1 TABLET BY MOUTH DAILY WITH BREAKFAST"
        assert_equal expected, mr.dosage_instruction
        assert_equal expected, mr.to_fhir.dig(:dosageInstruction, 0, :text)
      end

      test "from_rpms_row leaves dosageInstruction absent when the order has no instruction lines" do
        mr = active_medication(status: "ACTIVE", lines: [])
        assert_nil mr.to_fhir[:dosageInstruction]
      end

      test "to_fhir omits RxNorm coding when RPMS does not supply a medication code" do
        mr = MedicationRequest.new(
          ien: "2",
          patient_dfn: "1",
          medication_display: "Metformin 500mg",
          status: "active",
          intent: "order"
        )

        assert_nil mr.to_fhir.dig(:medicationCodeableConcept, :coding)
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
