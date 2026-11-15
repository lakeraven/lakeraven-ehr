# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # #904: every service-layer ordering entry point refuses MAT/MOUD.
    # The refusal reads the medication text only (no RxNorm lookup).
    class MatMoudOrderingRefusalTest < ActiveSupport::TestCase
      REFUSAL = %r{MAT/MOUD}i

      # Counts every call that would reach a pharmacy.
      class SpyAdapter < Eprescribing::MockAdapter
        attr_reader :sent, :changes, :approved

        def send_prescription(order)
          (@sent ||= []) << order
          super
        end

        def request_change(transmission_id, **options)
          (@changes ||= []) << options
          super
        end

        def approve_change(change_id)
          (@approved ||= []) << change_id
          super
        end
      end

      class SpyEprescribingService
        attr_reader :transmitted

        def transmit(order, provider_duz:)
          (@transmitted ||= []) << order
          Eprescribing::TransmissionResult.success(transmission_id: "spy-1")
        end
      end

      setup do
        @_orig_rpms_client = RpmsRpc.configuration.client
        RpmsRpc.mock!(&BASELINE_MOCK_SEEDS)
        @_orig_allergy_for_patient = AllergyIntolerance.method(:for_patient)
        AllergyIntolerance.define_singleton_method(:for_patient) { |_dfn| [] }
        @adapter = SpyAdapter.new
        @erx = EprescribingService.new(adapter: @adapter)
        @restore = []
      end

      teardown do
        @restore.each { |klass| klass.singleton_class.send(:remove_method, :new) }
        RpmsRpc.configure { |c| c.client = @_orig_rpms_client }
        AllergyIntolerance.define_singleton_method(:for_patient, @_orig_allergy_for_patient)
      end

      test "create_medication_order refuses MAT/MOUD with no order, no audit event and no interaction check" do
        consulted = []
        replace_new(DrugInteractionService) { consulted << :check; raise "DrugInteractionService must not be consulted" }

        [ "Buprenorphine-Naloxone 8 mg-2 mg SL film", "methadone 10 mg/mL oral concentrate", "Vivitrol 380 mg IM" ].each do |med|
          audits_before = AuditEvent.count
          result = begin
            CpoeService.create_medication_order(patient_dfn: "12345", provider_duz: "789", medication: med)
          rescue RuntimeError
            flunk "#{med}: not refused before the interaction check"
          end

          refute result.success?, "#{med} must be refused"
          assert_nil result.order
          assert(result.errors.any? { |e| e.match?(REFUSAL) }, "errors should say MAT/MOUD ordering is not offered: #{result.errors.inspect}")
          assert_equal audits_before, AuditEvent.count, "no CpoeAuditor event for a refused order"
        end
        assert_empty consulted
      end

      test "create_medication_order still accepts an ordinary medication" do
        result = CpoeService.create_medication_order(patient_dfn: "12345", provider_duz: "789", medication: "Sertraline 50 mg tablet")

        assert result.success?, result.errors.inspect
        assert_equal "draft", result.order.status
      end

      test "sign_order refuses a MAT/MOUD or unreadable MedicationRequest built outside create_medication_order" do
        spy = SpyEprescribingService.new
        replace_new(EprescribingService) { spy }

        [ "SUBOXONE 8 mg-2 mg film", "Naltrexone 50 mg tablet", nil, "  " ].each do |display|
          order = medication_order(display, status: "draft", intent: "plan")
          result = CpoeService.sign_order(order, provider_duz: "789")

          refute result.success?, "#{display.inspect} must not sign"
          assert(result.errors.any? { |e| e.match?(REFUSAL) }, result.errors.inspect)
          assert_equal "draft", order.status
          assert_equal "plan", order.intent
        end
        assert_nil spy.transmitted, "EprescribingService must never be asked to transmit"
      end

      test "sign_order still signs a lab order and an ordinary medication" do
        lab = CpoeService.create_lab_order(patient_dfn: "12345", provider_duz: "789", test_name: "CBC").order
        assert CpoeService.sign_order(lab, provider_duz: "789").success?
        assert_equal "active", lab.status

        med = medication_order("Lisinopril 10mg", status: "draft", intent: "plan")
        assert CpoeService.sign_order(med, provider_duz: "789", transmit: false).success?
        assert_equal "active", med.status
      end

      test "transmit refuses an active MAT/MOUD or unreadable order without calling the adapter" do
        [ "Methadone 10 mg tablet", "Sublocade 300 mg", "", nil ].each do |display|
          audits_before = AuditEvent.count
          result = @erx.transmit(medication_order(display), provider_duz: "789")

          assert_kind_of Eprescribing::TransmissionResult, result
          refute result.success?, "#{display.inspect} must not transmit"
          assert(result.errors.any? { |e| e.match?(REFUSAL) }, result.errors.inspect)
          assert_equal audits_before, AuditEvent.count
        end
        assert_nil @adapter.sent, "send_prescription must never be called"
      end

      test "transmit still sends an ordinary active order" do
        result = @erx.transmit(medication_order("Lisinopril 10mg"), provider_duz: "789")

        assert result.success?, result.errors.inspect
        assert_equal 1, @adapter.sent.size
      end

      test "request_change refuses a MAT/MOUD or unreadable new_medication without calling the adapter" do
        sent = @erx.transmit(medication_order("Lisinopril 10mg"), provider_duz: "789")

        [ "Buprenorphine 8 mg SL tablet", "Antabuse 250 mg", nil, "" ].each do |new_medication|
          result = @erx.request_change(sent.transmission_id, pharmacy_ncpdpid: "1234567", new_medication: new_medication)

          refute result.success?, "#{new_medication.inspect} must not be requested"
          assert(result.errors.any? { |e| e.match?(REFUSAL) }, result.errors.inspect)
        end
        assert_nil @adapter.changes, "adapter request_change must never be called"
      end

      test "request_change still passes an ordinary new_medication to the adapter" do
        sent = @erx.transmit(medication_order("Lisinopril 10mg"), provider_duz: "789")
        result = @erx.request_change(sent.transmission_id, pharmacy_ncpdpid: "1234567", new_medication: "Lisinopril 20mg")

        assert result.success?, result.errors.inspect
        assert_equal 1, @adapter.changes.size
      end

      # Amendment 1: the medication behind a pharmacy change id cannot be read
      # here, so approving one is refused whatever the id.
      test "approve_change refuses every change id without calling the adapter" do
        sent = @erx.transmit(medication_order("Lisinopril 10mg"), provider_duz: "789")
        change = @erx.request_change(sent.transmission_id, pharmacy_ncpdpid: "1234567", new_medication: "Lisinopril 20mg")
        assert change.success?, change.errors.inspect

        [ change.transmission_id, "change-unknown", "", nil ].each do |change_id|
          audits_before = AuditEvent.count
          result = @erx.approve_change(change_id, provider_duz: "789")

          assert_kind_of Eprescribing::TransmissionResult, result
          refute result.success?, "#{change_id.inspect} must not be approved"
          assert(result.errors.any? { |e| e.match?(REFUSAL) }, result.errors.inspect)
          assert_equal audits_before, AuditEvent.count
        end
        assert_nil @adapter.approved, "adapter approve_change must never be called"
      end

      private

      def replace_new(klass, &block)
        klass.define_singleton_method(:new) { |*_args, **_kwargs| block.call }
        @restore << klass
      end

      def medication_order(display, status: "active", intent: "order")
        MedicationRequest.new(
          ien: "med-#{SecureRandom.hex(4)}", patient_dfn: "12345", requester_duz: "789",
          medication_display: display, status: status, intent: intent,
          dosage_instruction: "Take as directed", authored_on: Time.current
        )
      end
    end
  end
end
