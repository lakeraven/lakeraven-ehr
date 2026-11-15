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
          # Amendment 4: say why. Nothing was ordered here, so the bare
          # "MAT/MOUD ordering is not offered" message would mislead; the
          # error names the pharmacy change that was not approved.
          assert_equal 1, result.errors.size, result.errors.inspect
          refute_includes result.errors, MatMoudMedication::REFUSAL, "approve_change needs its own message"
          refute_includes result.errors, MatMoudMedication::UNREADABLE, "nothing was typed, so nothing was unreadable"
          assert_match(/change/i, result.errors.first)
          assert_equal audits_before, AuditEvent.count
        end
        assert_nil @adapter.approved, "adapter approve_change must never be called"
      end

      # --- Amendment 3: say why ---------------------------------------------
      # Unreadable text and a readable MAT/MOUD name are both refused, with
      # different messages, so staff can tell "we do not offer this" from "we
      # could not read what you typed".
      UNREADABLE = /could not be read/i

      test "refusal_for is nil for orderable text, not-offered for MAT/MOUD and could-not-be-read for unreadable text" do
        [ "Sertraline 50 mg tablet", "Lisinopril 10mg" ].each do |text|
          assert_nil MatMoudMedication.refusal_for(text), text.inspect
        end

        [ "Buprenorphine 8 mg SL tablet", "SUBOXONE", "Revia 50 mg" ].each do |text|
          message = MatMoudMedication.refusal_for(text)
          assert_equal MatMoudMedication::REFUSAL, message, text.inspect
          assert_match(/not offered/i, message)
          refute_match UNREADABLE, message, "a readable MAT/MOUD name is not an unreadable one"
        end

        [ nil, "", "   ", 12_345, "Café med 10 mg", "methаdone 10 mg", "methadone\xFF" ].each do |text|
          message = MatMoudMedication.refusal_for(text)
          assert_kind_of String, message, text.inspect
          assert_match REFUSAL, message, text.inspect
          assert_match UNREADABLE, message, text.inspect
          refute_equal MatMoudMedication::REFUSAL, message, "unreadable text gets its own message"
        end
      end

      test "create_medication_order says an unreadable medication could not be read" do
        medication = "Café med 10 mg"
        audits_before = AuditEvent.count
        result = CpoeService.create_medication_order(patient_dfn: "12345", provider_duz: "789", medication: medication)

        refute result.success?
        assert_nil result.order
        assert_equal [ MatMoudMedication.refusal_for(medication) ], result.errors
        assert_match UNREADABLE, result.errors.first
        assert_match REFUSAL, result.errors.first
        assert_equal audits_before, AuditEvent.count
      end

      test "create_medication_order says a readable MAT/MOUD name is not offered, not unreadable" do
        result = CpoeService.create_medication_order(patient_dfn: "12345", provider_duz: "789", medication: "Vivitrol 380 mg IM")

        refute result.success?
        assert_equal [ MatMoudMedication::REFUSAL ], result.errors
        refute_match UNREADABLE, result.errors.first
      end

      test "transmit says an order with no medication text could not be read" do
        result = @erx.transmit(medication_order(nil), provider_duz: "789")

        refute result.success?
        assert_equal [ MatMoudMedication.refusal_for(nil) ], result.errors
        assert_match UNREADABLE, result.errors.first
        assert_match REFUSAL, result.errors.first
        assert_nil @adapter.sent, "send_prescription must never be called"
      end

      test "transmit says a readable MAT/MOUD order is not offered, not unreadable" do
        result = @erx.transmit(medication_order("Methadone 10 mg tablet"), provider_duz: "789")

        refute result.success?
        assert_equal [ MatMoudMedication::REFUSAL ], result.errors
        refute_match UNREADABLE, result.errors.first
      end

      test "request_change says a missing new_medication could not be read" do
        sent = @erx.transmit(medication_order("Lisinopril 10mg"), provider_duz: "789")
        result = @erx.request_change(sent.transmission_id, pharmacy_ncpdpid: "1234567", new_medication: nil)

        refute result.success?
        assert_equal [ MatMoudMedication.refusal_for(nil) ], result.errors
        assert_match UNREADABLE, result.errors.first
        assert_match REFUSAL, result.errors.first
        assert_nil @adapter.changes, "adapter request_change must never be called"
      end

      test "request_change says a readable MAT/MOUD new_medication is not offered, not unreadable" do
        sent = @erx.transmit(medication_order("Lisinopril 10mg"), provider_duz: "789")
        result = @erx.request_change(sent.transmission_id, pharmacy_ncpdpid: "1234567", new_medication: "Antabuse 250 mg")

        refute result.success?
        assert_equal [ MatMoudMedication::REFUSAL ], result.errors
        refute_match UNREADABLE, result.errors.first
      end

      # --- Amendment 4: the sig is read too -----------------------------------
      # The dosage instruction is free text that NcpdpScriptGenerator sends to
      # the pharmacy as SigText and Directions, so it is classified with the
      # same rule as the medication text. A nil or blank sig is allowed (for
      # this field only); any other sig must be :not_mat_moud.
      #
      # Helper pinned: MatMoudMedication.refusal_for_order(medication_text,
      # sig_text) returns the first non-nil refusal, medication first.

      test "refusal_for_order is nil when the medication is orderable and the sig is blank or orderable" do
        [ nil, "", "   ", "\t\n", "take 1 tab daily", "Take as directed" ].each do |sig|
          assert_nil MatMoudMedication.refusal_for_order("Sertraline 50 mg tablet", sig), sig.inspect
        end
      end

      test "refusal_for_order refuses a MAT/MOUD name or unreadable text in the sig" do
        [ "METHADONE 40 mg by mouth daily", "Suboxone 8 mg SL daily", "1 tab daily (naltrexone)" ].each do |sig|
          assert_equal MatMoudMedication::REFUSAL, MatMoudMedication.refusal_for_order("oral solution 10 mg/mL", sig), sig.inspect
        end
        [ "Take \u00BD tab", "meth\u0430done 40 mg daily", "take 1 tab\xFF", 40, [ "take 1 tab daily" ] ].each do |sig|
          assert_equal MatMoudMedication::UNREADABLE, MatMoudMedication.refusal_for_order("Sertraline 50 mg tablet", sig), sig.inspect
        end
      end

      test "refusal_for_order reads the medication first and never allows a blank medication" do
        assert_equal MatMoudMedication::REFUSAL, MatMoudMedication.refusal_for_order("Methadone 10 mg tablet", nil)
        assert_equal MatMoudMedication::REFUSAL, MatMoudMedication.refusal_for_order("Methadone 10 mg tablet", "Take \u00BD tab")
        assert_equal MatMoudMedication::UNREADABLE, MatMoudMedication.refusal_for_order("Caf\u00E9 med 10 mg", "methadone 40 mg daily")
        [ nil, "", "   " ].each do |medication|
          assert_equal MatMoudMedication::UNREADABLE, MatMoudMedication.refusal_for_order(medication, "take 1 tab daily"),
            medication.inspect
          assert_equal MatMoudMedication::UNREADABLE, MatMoudMedication.refusal_for_order(medication, nil), medication.inspect
        end
      end

      test "create_medication_order refuses a MAT/MOUD name in the dosage with no order, no audit event and no interaction check" do
        consulted = []
        replace_new(DrugInteractionService) { consulted << :check; raise "DrugInteractionService must not be consulted" }
        audits_before = AuditEvent.count

        result = begin
          CpoeService.create_medication_order(patient_dfn: "12345", provider_duz: "789", medication: "oral solution 10 mg/mL",
            dosage: "METHADONE 40 mg by mouth daily")
        rescue RuntimeError
          flunk "a MAT/MOUD sig was not refused before the interaction check"
        end

        refute result.success?, "a MAT/MOUD name in the sig must be refused"
        assert_nil result.order
        assert_equal [ MatMoudMedication::REFUSAL ], result.errors
        assert_equal audits_before, AuditEvent.count
        assert_empty consulted
      end

      test "create_medication_order says an unreadable dosage could not be read" do
        audits_before = AuditEvent.count
        result = CpoeService.create_medication_order(patient_dfn: "12345", provider_duz: "789", medication: "Sertraline 50 mg tablet",
          dosage: "Take \u00BD tab")

        refute result.success?
        assert_nil result.order
        assert_equal 1, result.errors.size, result.errors.inspect
        assert_match UNREADABLE, result.errors.first
        assert_match REFUSAL, result.errors.first
        refute_equal MatMoudMedication::REFUSAL, result.errors.first
        assert_equal audits_before, AuditEvent.count
      end

      test "create_medication_order still accepts an ordinary medication with an ordinary, blank or missing dosage" do
        [ { dosage: "take 1 tab daily" }, { dosage: "" }, { dosage: nil }, {} ].each do |options|
          result = CpoeService.create_medication_order(patient_dfn: "12345", provider_duz: "789",
            medication: "Sertraline 50 mg tablet", **options)

          assert result.success?, "#{options.inspect}: #{result.errors.inspect}"
          assert_equal "draft", result.order.status
          assert_equal "Sertraline 50 mg tablet", result.order.medication_display
        end
      end

      test "sign_order refuses a MedicationRequest whose dosage instruction names MAT/MOUD or cannot be read" do
        spy = SpyEprescribingService.new
        replace_new(EprescribingService) { spy }

        { "Suboxone 8 mg SL daily" => MatMoudMedication::REFUSAL, "Take \u00BD tab" => MatMoudMedication::UNREADABLE }.each do |sig, message|
          order = medication_order("oral film", status: "draft", intent: "plan", dosage: sig)
          audits_before = AuditEvent.count
          result = CpoeService.sign_order(order, provider_duz: "789")

          refute result.success?, "#{sig.inspect} must not sign"
          assert_equal [ message ], result.errors
          assert_equal "draft", order.status
          assert_equal "plan", order.intent
          assert_equal audits_before, AuditEvent.count
        end
        assert_nil spy.transmitted, "EprescribingService must never be asked to transmit"
      end

      test "sign_order still signs an ordinary medication with a blank or missing dosage instruction" do
        [ nil, "", "take 1 tab daily" ].each do |sig|
          med = medication_order("Lisinopril 10mg", status: "draft", intent: "plan", dosage: sig)
          assert CpoeService.sign_order(med, provider_duz: "789", transmit: false).success?, sig.inspect
          assert_equal "active", med.status
        end
      end

      test "transmit refuses an active order whose dosage instruction names MAT/MOUD or cannot be read, without calling the adapter" do
        { "methadone 40 mg daily" => MatMoudMedication::REFUSAL, "Take \u00BD tab" => MatMoudMedication::UNREADABLE }.each do |sig, message|
          audits_before = AuditEvent.count
          result = @erx.transmit(medication_order("oral solution 10 mg/mL", dosage: sig), provider_duz: "789")

          assert_kind_of Eprescribing::TransmissionResult, result
          refute result.success?, "#{sig.inspect} must not transmit"
          assert_equal [ message ], result.errors
          assert_equal audits_before, AuditEvent.count
        end
        assert_nil @adapter.sent, "send_prescription must never be called"
      end

      test "transmit still sends an ordinary active order with a blank or missing dosage instruction" do
        [ nil, "", "take 1 tab daily" ].each do |sig|
          result = @erx.transmit(medication_order("Lisinopril 10mg", dosage: sig), provider_duz: "789")
          assert result.success?, "#{sig.inspect}: #{result.errors.inspect}"
        end
        assert_equal 3, @adapter.sent.size
      end

      private

      def replace_new(klass, &block)
        klass.define_singleton_method(:new) { |*_args, **_kwargs| block.call }
        @restore << klass
      end

      def medication_order(display, status: "active", intent: "order", dosage: "Take as directed")
        MedicationRequest.new(
          ien: "med-#{SecureRandom.hex(4)}", patient_dfn: "12345", requester_duz: "789",
          medication_display: display, status: status, intent: intent,
          dosage_instruction: dosage, authored_on: Time.current
        )
      end
    end
  end
end
