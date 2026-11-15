# frozen_string_literal: true

require "test_helper"
require "digest"

module Lakeraven
  module EHR
    # lakeraven-ehr#960: signing a progress note writes exactly one
    # append-only AuditEvent per call, on every path, carrying a hash of the
    # signed text and never the signature code or the text itself.
    class ProgressNoteServiceSignAuditTest < ActiveSupport::TestCase
      DFN = 8791
      VISIT_IEN = 2090061
      AUTHOR_DUZ = 2843
      NOTE_IEN = 7801
      SIGNATURE_CODE = "SIGSECRET42"
      NOTE_TEXT = "S: Synthetic sore throat x3 days.\nP: Supportive care; return if worsening."

      class FakeNoteGateway
        attr_reader :fetches
        attr_accessor :text

        def initialize(text: nil)
          @text = text
          @fetches = []
        end

        def create(_dfn, _visit_ien, _title_ien) = { success: true, ien: NOTE_IEN, raw: NOTE_IEN.to_s }

        def update_text(_note_ien, text)
          @text = text
          { success: true, raw: "1" }
        end

        def fetch_text(note_ien)
          @fetches << note_ien
          @text
        end
      end

      class FakeESignatureGateway
        attr_reader :validations, :sign_actions

        def initialize(validation: { success: true, raw: "1" }, add_result: { success: true, raw: "1" })
          @validation = validation
          @add_result = add_result
          @validations = []
          @sign_actions = []
        end

        def validate(user_duz, signature_code)
          @validations << { user_duz: user_duz, signature_code: signature_code }
          @validation
        end

        def add(note_ien, user_duz, signature_code, action: :sign)
          @sign_actions << { note_ien: note_ien, user_duz: user_duz, signature_code: signature_code, action: action }
          @add_result
        end
      end

      setup do
        @note_gateway = FakeNoteGateway.new(text: NOTE_TEXT)
        @esig_gateway = FakeESignatureGateway.new
      end

      # -- success ---------------------------------------------------------

      test "signing a note writes exactly one audit event" do
        assert_difference "Lakeraven::EHR::AuditEvent.count", 1 do
          result = sign
          assert result.success?, "signing failed: #{result.error.inspect}"
        end
      end

      test "the success event names the actor, the note, the action and a success outcome" do
        event = audit_event_for { sign }

        assert_equal "application", event.event_type
        assert_equal "E", event.action
        assert_equal "0", event.outcome
        assert_equal "Practitioner", event.agent_who_type
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
        assert_equal "DocumentReference", event.entity_type
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal NOTE_IEN.to_s, event.entity_id.to_s
      end

      test "the success event names the patient and the SHA-256 of the fetched note text" do
        event = audit_event_for { sign }

        expected = "progress_note_signed; patient #{DFN}; content-sha256 #{Digest::SHA256.hexdigest(NOTE_TEXT)}"
        assert_equal expected, event.outcome_desc
        assert_match(/content-sha256 [0-9a-f]{64}\z/, event.outcome_desc)
      end

      test "the note text is read through the note gateway for the note being signed" do
        sign

        assert_equal [ NOTE_IEN.to_s ], @note_gateway.fetches.map(&:to_s)
      end

      test "the recorded hash is of the fetched text, so different text gives a different hash" do
        first = audit_event_for { sign }

        @note_gateway.text = "#{NOTE_TEXT}\nAddendum: synthetic late change."
        second = audit_event_for { sign }

        assert_includes second.outcome_desc, Digest::SHA256.hexdigest(@note_gateway.text)
        refute_equal content_hash(first), content_hash(second)
      end

      test "the success event holds neither the signature code nor the note text" do
        event = audit_event_for { sign }

        refute_leaks event, SIGNATURE_CODE
        refute_leaks event, NOTE_TEXT
        NOTE_TEXT.lines.map(&:strip).each { |line| refute_leaks event, line }
      end

      test "the Result and the sign action are unchanged on success" do
        result = sign

        assert result.success?
        assert_equal NOTE_IEN, result.note_ien
        assert_equal 1, @esig_gateway.sign_actions.size
        assert_equal 1, Lakeraven::EHR::AuditEvent.where(entity_type: "DocumentReference").count
      end

      # -- refusals (outcome "4") -------------------------------------------

      test "an invalid signature code writes a refusal event and sends no sign action" do
        @esig_gateway = FakeESignatureGateway.new(validation: { success: false, raw: "0^Invalid code" })

        event = audit_event_for do
          result = sign
          assert_equal :invalid_signature_code, result.error
        end

        assert_empty @esig_gateway.sign_actions
        assert_equal "4", event.outcome
        assert_equal "E", event.action
        assert_equal "application", event.event_type
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
        assert_equal "DocumentReference", event.entity_type
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal "progress_note_sign_refused; patient #{DFN}; reason invalid_signature_code", event.outcome_desc
        refute_match(/sha256/i, event.outcome_desc)
        refute_leaks event, SIGNATURE_CODE
      end

      test "signing with no note writes a refusal event with no entity identifier" do
        event = audit_event_for do
          result = sign(note_ien: nil)
          assert_equal :no_note, result.error
        end

        assert_empty @esig_gateway.validations
        assert_empty @esig_gateway.sign_actions
        assert_equal "4", event.outcome
        assert_equal "DocumentReference", event.entity_type
        assert_nil event.entity_identifier
        assert_nil event.entity_id
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
        assert_equal "progress_note_sign_refused; patient #{DFN}; reason no_note", event.outcome_desc
        refute_leaks event, SIGNATURE_CODE
      end

      test "a note whose text cannot be read is not signed" do
        @note_gateway.text = nil

        event = audit_event_for do
          result = sign
          refute result.success?
          assert_equal :note_text_unavailable, result.error
        end

        assert_empty @esig_gateway.sign_actions
        assert_equal "4", event.outcome
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal "progress_note_sign_refused; patient #{DFN}; reason note_text_unavailable", event.outcome_desc
        refute_match(/sha256/i, event.outcome_desc)
        refute_leaks event, SIGNATURE_CODE
      end

      test "note text that is not a String is treated as unavailable" do
        @note_gateway.text = { success: false, raw: nil }

        result = sign

        assert_equal :note_text_unavailable, result.error
        assert_empty @esig_gateway.sign_actions
      end

      # -- gateway errors (outcome "8") --------------------------------------

      test "a failed sign action writes a serious-failure event" do
        @esig_gateway = FakeESignatureGateway.new(add_result: { success: false, raw: "0^record locked" })

        event = audit_event_for do
          result = sign
          assert_equal :gateway_error, result.error
        end

        assert_equal "8", event.outcome
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal "progress_note_sign_refused; patient #{DFN}; reason gateway_error", event.outcome_desc
        refute_match(/sha256/i, event.outcome_desc)
        refute_leaks event, SIGNATURE_CODE
      end

      test "a non-Hash validation reply writes a serious-failure event and sends no sign action" do
        @esig_gateway = FakeESignatureGateway.new(validation: nil)

        event = audit_event_for do
          result = sign
          assert_equal :gateway_error, result.error
        end

        assert_empty @esig_gateway.sign_actions
        assert_equal "8", event.outcome
        assert_equal "progress_note_sign_refused; patient #{DFN}; reason gateway_error", event.outcome_desc
        refute_leaks event, SIGNATURE_CODE
      end

      # -- immutability ------------------------------------------------------

      test "the signing event cannot be updated" do
        event = audit_event_for { sign }

        assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(outcome: "8") }
        assert_equal "0", Lakeraven::EHR::AuditEvent.find(event.id).outcome
      end

      test "the signing event cannot be destroyed" do
        event = audit_event_for { sign }

        assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy }
        assert Lakeraven::EHR::AuditEvent.exists?(event.id)
      end

      # -- fail closed -------------------------------------------------------

      test "the event is written with create_detached!" do
        with_recording_stub(Lakeraven::EHR::AuditEvent, :create_detached!, nil) do |calls|
          sign

          assert_equal 1, calls.size, "sign must write its audit event through AuditEvent.create_detached!"
        end
      end

      test "sign raises when the audit event cannot be written" do
        with_failing_audit_write do
          error = assert_raises(ActiveRecord::StatementInvalid) { sign }
          assert_equal "audit down", error.message
        end
      end

      test "a refused signing raises too when the audit event cannot be written" do
        @esig_gateway = FakeESignatureGateway.new(validation: { success: false, raw: "0^Invalid code" })

        with_failing_audit_write do
          assert_raises(ActiveRecord::StatementInvalid) { sign }
        end
        assert_empty @esig_gateway.sign_actions
      end

      private

      def service
        ProgressNoteService.new(
          dfn: DFN, visit_ien: VISIT_IEN, author_duz: AUTHOR_DUZ,
          gateway: @note_gateway, esignature_gateway: @esig_gateway
        )
      end

      def sign(note_ien: NOTE_IEN, signature_code: SIGNATURE_CODE)
        service.sign(note_ien: note_ien, signature_code: signature_code)
      end

      # Runs the block and returns the one AuditEvent it wrote.
      def audit_event_for(&block)
        before = Lakeraven::EHR::AuditEvent.pluck(:id)
        block.call
        written = Lakeraven::EHR::AuditEvent.where.not(id: before).to_a
        assert_equal 1, written.size, "expected exactly one AuditEvent from sign, got #{written.size}"
        written.first
      end

      def content_hash(event)
        event.outcome_desc[/content-sha256 ([0-9a-f]{64})/, 1]
      end

      def refute_leaks(event, secret)
        event.attributes.each do |column, value|
          next if value.nil?

          refute_includes value.to_s, secret, "AuditEvent##{column} must not contain #{secret.inspect}"
        end
      end

      # Minitest 6 dropped minitest/mock (no Object#stub), so the failure is
      # injected by swapping the singleton method and restoring it after.
      def with_failing_audit_write
        restore = singleton_method_restore(Lakeraven::EHR::AuditEvent, :create_detached!)
        Lakeraven::EHR::AuditEvent.define_singleton_method(:create_detached!) do |*_args, **_kwargs|
          raise ActiveRecord::StatementInvalid, "audit down"
        end
        yield
      ensure
        restore&.call
      end
    end
  end
end
