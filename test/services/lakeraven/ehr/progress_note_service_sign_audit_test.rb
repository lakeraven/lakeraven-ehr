# frozen_string_literal: true

require "test_helper"
require "digest"

module Lakeraven
  module EHR
    # lakeraven-ehr#960: signing a progress note writes exactly one
    # append-only AuditEvent per call, on every path, carrying a hash of the
    # signed note body and never the signature code or the text itself.
    #
    # The success row carries two hashes. content-sha256 is of the body rows
    # read BEFORE the sign action: what was signed. record-sha256 is of ALL
    # the body rows read again AFTER it: the note as filed, signature block
    # included. A verifier re-reads the body and compares the hash of all its
    # rows with record-sha256, so an appended, removed or edited row shows.
    #
    # The fakes model the production gateways: ESignatureGateway.validate
    # returns true or false, and only true is an accepted code (any other
    # answer, a Hash included, is a gateway error), and the note gateway's
    # fetch_body returns the body rows of the TIU text, without the header.
    class ProgressNoteServiceSignAuditTest < ActiveSupport::TestCase
      DFN = 8791
      VISIT_IEN = 2090061
      AUTHOR_DUZ = 2843
      NOTE_IEN = 7801
      SIGNATURE_CODE = "SIGSECRET42"
      NOTE_ROWS = [
        "S: Synthetic sore throat x3 days.",
        "",
        "P: Supportive care; return if worsening."
      ].freeze
      NOTE_BODY = NOTE_ROWS.join("\n")
      NOTE_HASH = Digest::SHA256.hexdigest(NOTE_BODY)
      # The body as TIU returns it once signed: the same rows, then the
      # signature block.
      SIGNED_ROWS = (NOTE_ROWS + [ "", "/es/ SYNTHETIC PROVIDER" ]).freeze
      SIGNED_HASH = Digest::SHA256.hexdigest(SIGNED_ROWS.join("\n"))
      # SHA-256 of nothing and of an empty row list's join: an absent record
      # must never be written as either.
      EMPTY_HASH = Digest::SHA256.hexdigest("")
      # A String whose bytes are not valid in its encoding: not a body row.
      INVALID_ENCODING_ROW = "S: ok \xFF row".dup.force_encoding("UTF-8").freeze

      # Raised by the fakes. The message carries the signature code so a row
      # that copied the exception message would leak it.
      class GatewayDown < StandardError; end
      GATEWAY_DOWN_MESSAGE = "broker dropped the call carrying #{SIGNATURE_CODE}"

      # Models ProgressNoteGateway: fetch_body returns the body rows. There is
      # deliberately no fetch_text, so a service that hashes the whole TIU
      # display (header and signature block included) fails here.
      #
      # The first fetch_body of a gateway is the pre-sign read and returns
      # +rows+. Every later one is the post-sign read: it returns +post_sign+
      # when that was given (nil included), else +rows+ again, and raises
      # +post_sign_error+ when that was given.
      class FakeNoteGateway
        SAME = Object.new.freeze

        attr_reader :fetches
        attr_accessor :rows

        def initialize(rows: nil, error: nil, post_sign: SAME, post_sign_error: nil)
          @rows = rows
          @error = error
          @post_sign = post_sign
          @post_sign_error = post_sign_error
          @fetches = []
        end

        def create(_dfn, _visit_ien, _title_ien) = { success: true, ien: NOTE_IEN, raw: NOTE_IEN.to_s }

        def update_text(_note_ien, text)
          @rows = text.to_s.split("\n", -1)
          { success: true, raw: "1" }
        end

        def fetch_body(note_ien)
          @fetches << note_ien
          raise @error if @error
          return @rows if @fetches.size == 1

          raise @post_sign_error if @post_sign_error

          @post_sign.equal?(SAME) ? @rows : @post_sign
        end
      end

      class FakeESignatureGateway
        attr_reader :validations, :sign_actions

        def initialize(validation: true, add_result: { success: true, raw: "1" },
                       validate_error: nil, add_error: nil)
          @validation = validation
          @add_result = add_result
          @validate_error = validate_error
          @add_error = add_error
          @validations = []
          @sign_actions = []
        end

        def validate(user_duz, signature_code)
          @validations << { user_duz: user_duz, signature_code: signature_code }
          raise @validate_error if @validate_error

          @validation
        end

        def add(note_ien, user_duz, signature_code, action: :sign)
          @sign_actions << { note_ien: note_ien, user_duz: user_duz, signature_code: signature_code, action: action }
          raise @add_error if @add_error

          @add_result
        end
      end

      setup do
        @note_gateway = FakeNoteGateway.new(rows: NOTE_ROWS.dup)
        @esig_gateway = FakeESignatureGateway.new
      end

      # reset clears every attribute, inside_audited_request included.
      teardown do
        AuditContext.inside_audited_request = nil
        AuditContext.reset
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

      test "the success event names the patient, then the signed body and the filed record, each as a SHA-256 and a row count" do
        @note_gateway = FakeNoteGateway.new(rows: NOTE_ROWS.dup, post_sign: SIGNED_ROWS.dup)

        event = audit_event_for do
          result = sign
          assert result.success?, "signing failed: #{result.error.inspect}"
        end

        assert_equal "progress_note_signed; patient #{DFN}; content-sha256 #{NOTE_HASH}; content-rows 3; " \
                     "record-sha256 #{SIGNED_HASH}; record-rows 5",
                     event.outcome_desc
        assert_equal success_desc(NOTE_ROWS, SIGNED_ROWS), event.outcome_desc
        assert_match(/content-sha256 [0-9a-f]{64}; content-rows \d+; record-sha256 [0-9a-f]{64}; record-rows \d+\z/,
                     event.outcome_desc)
        refute_equal content_hash(event), record_hash(event)
      end

      test "a body that signing does not change records the same hash and count twice" do
        event = audit_event_for { sign }

        assert_equal "progress_note_signed; patient #{DFN}; content-sha256 #{NOTE_HASH}; content-rows 3; " \
                     "record-sha256 #{NOTE_HASH}; record-rows 3",
                     event.outcome_desc
      end

      test "the body is read exactly twice on success: before the sign action and after it" do
        sign

        assert_equal [ NOTE_IEN.to_s, NOTE_IEN.to_s ], @note_gateway.fetches.map(&:to_s)
        assert_equal 1, @esig_gateway.sign_actions.size
      end

      # THE DEFECT: a verifier that hashed only the first content-rows rows
      # passed a note with rows appended after signing. The record hash is of
      # every row, so an appended, removed or edited row no longer matches.
      test "the record hash covers every filed row, so a later append, removal or edit is detected" do
        @note_gateway = FakeNoteGateway.new(rows: NOTE_ROWS.dup, post_sign: SIGNED_ROWS.dup)
        event = audit_event_for { sign }
        verify = ->(rows) { Digest::SHA256.hexdigest(rows.join("\n")) == record_hash(event) }

        assert verify.call(SIGNED_ROWS), "an unchanged signed note must verify"
        refute verify.call(SIGNED_ROWS + [ "Addendum: synthetic row appended after signing." ])
        refute verify.call(SIGNED_ROWS[0..-2])
        refute verify.call([ "S: Synthetic row edited after signing." ] + SIGNED_ROWS.drop(1))
        assert_equal content_hash(event),
                     Digest::SHA256.hexdigest((SIGNED_ROWS + [ "appended" ]).first(content_rows(event)).join("\n")),
                     "the first content-rows rows alone do not show the append"
      end

      # -- the filed record must start with what was signed -------------------

      # The rows signed are the n pre-sign rows. A filed body whose first n
      # rows are not exactly those rows is not the signed note with a
      # signature block after it: the text changed between the signer's read
      # and filing. The signature happened, so the row is still a success, but
      # it ends "record-sha256 mismatch", a marker that never verifies.
      {
        "an edited signed row" => [ "EDITED", "b", "", "/es/ SYNTHETIC" ],
        "fewer rows than were signed" => [ "a" ]
      }.each do |label, post_sign|
        test "a filed record with #{label} writes the success event, with record-sha256 mismatch" do
          @note_gateway = FakeNoteGateway.new(rows: [ "a", "b" ], post_sign: post_sign)

          result = nil
          event = audit_event_for { result = assert_nothing_raised { sign } }

          assert result.success?, "the signature happened, so sign succeeds: #{result.error.inspect}"
          assert_equal NOTE_IEN, result.note_ien
          assert_equal 1, @esig_gateway.sign_actions.size
          assert_equal 2, @note_gateway.fetches.size
          assert_equal "0", event.outcome
          assert_equal "#{content_desc([ "a", "b" ])}; record-sha256 mismatch", event.outcome_desc
          assert event.outcome_desc.end_with?("; content-rows 2; record-sha256 mismatch")
          refute_match(/record-sha256 [0-9a-f]{64}/, event.outcome_desc)
          refute_match(/record-rows/, event.outcome_desc)
          refute_leaks event, Digest::SHA256.hexdigest(post_sign.join("\n"))
          refute_leaks event, SIGNATURE_CODE
        end
      end

      test "a filed record that starts with the signed rows, then the signature block, records a normal record hash" do
        filed = [ "a", "b", "", "/es/ SYNTHETIC" ]
        @note_gateway = FakeNoteGateway.new(rows: [ "a", "b" ], post_sign: filed)

        event = audit_event_for do
          result = sign
          assert result.success?, "signing failed: #{result.error.inspect}"
        end

        assert_equal "0", event.outcome
        assert_equal success_desc([ "a", "b" ], filed), event.outcome_desc
        assert event.outcome_desc.end_with?("; record-sha256 #{Digest::SHA256.hexdigest(filed.join("\n"))}; record-rows 4")
        refute_match(/mismatch/, event.outcome_desc)
      end

      # -- the post-sign read can fail; the signature already happened -------

      {
        "nil" => nil,
        "an empty body" => [],
        "a body of blank rows" => [ "", "  " ],
        "a String, not rows" => NOTE_BODY,
        "rows that are not all Strings" => [ "S: Synthetic row.", 7 ],
        "a row holding a line feed" => [ "S: Synthetic row.\nP: Synthetic smuggled row." ],
        "a row with invalid encoding" => [ "S: Synthetic row.", INVALID_ENCODING_ROW ]
      }.each do |label, post_sign|
        test "a post-sign read returning #{label} still writes the success event, with record-sha256 unavailable" do
          @note_gateway = FakeNoteGateway.new(rows: NOTE_ROWS.dup, post_sign: post_sign)

          result = nil
          event = audit_event_for { result = assert_nothing_raised { sign } }

          assert result.success?, "the signature happened, so sign succeeds: #{result.error.inspect}"
          assert_equal NOTE_IEN, result.note_ien
          assert_equal 1, @esig_gateway.sign_actions.size
          assert_equal 2, @note_gateway.fetches.size
          assert_equal "0", event.outcome
          assert_equal unavailable_desc(NOTE_ROWS), event.outcome_desc
          assert event.outcome_desc.end_with?("; content-rows 3; record-sha256 unavailable")
          refute_match(/record-rows/, event.outcome_desc)
          refute_leaks event, EMPTY_HASH
          refute_leaks event, SIGNATURE_CODE
        end
      end

      test "a post-sign read that raises still writes the success event and does not raise" do
        boom = GatewayDown.new(GATEWAY_DOWN_MESSAGE)
        @note_gateway = FakeNoteGateway.new(rows: NOTE_ROWS.dup, post_sign_error: boom)

        result = nil
        event = audit_event_for { result = assert_nothing_raised { sign } }

        assert result.success?, "the signature happened, so sign succeeds: #{result.error.inspect}"
        assert_equal NOTE_IEN, result.note_ien
        assert_equal 1, @esig_gateway.sign_actions.size
        assert_equal 2, @note_gateway.fetches.size
        assert_equal "0", event.outcome
        assert_equal unavailable_desc(NOTE_ROWS), event.outcome_desc
        refute_match(/record-rows/, event.outcome_desc)
        refute_leaks event, GATEWAY_DOWN_MESSAGE
        refute_leaks event, "GatewayDown"
        refute_leaks event, EMPTY_HASH
        refute_leaks event, SIGNATURE_CODE
      end

      test "the recorded hash is of the fetched body, so a different body gives a different hash and count" do
        first = audit_event_for { sign }

        @note_gateway = FakeNoteGateway.new(rows: NOTE_ROWS + [ "Addendum: synthetic late change." ])
        second = audit_event_for { sign }

        assert_equal success_desc(@note_gateway.rows), second.outcome_desc
        assert_equal 3, content_rows(first)
        assert_equal 4, content_rows(second)
        refute_equal content_hash(first), content_hash(second)
      end

      test "the success event holds neither the signature code nor the note text" do
        event = audit_event_for { sign }

        refute_leaks event, SIGNATURE_CODE
        refute_leaks event, NOTE_BODY
        NOTE_ROWS.reject(&:empty?).each { |row| refute_leaks event, row }
      end

      test "the Result and the sign action are unchanged on success" do
        result = nil
        audit_event_for { result = sign }

        assert result.success?
        assert_equal NOTE_IEN, result.note_ien
        assert_equal 1, @esig_gateway.sign_actions.size
        assert_equal :sign, @esig_gateway.sign_actions.first[:action]
      end

      # -- validation reply shapes -------------------------------------------

      test "a Boolean true validation, as production returns, signs and writes a success event" do
        @esig_gateway = FakeESignatureGateway.new(validation: true)

        event = audit_event_for do
          result = sign
          assert result.success?, "signing failed: #{result.error.inspect}"
        end

        assert_equal 1, @esig_gateway.sign_actions.size
        assert_equal "0", event.outcome
        assert_equal success_desc(NOTE_ROWS), event.outcome_desc
      end

      test "a Hash validation reply, even one with a truthy :success, is a gateway error and never an acceptance" do
        @esig_gateway = FakeESignatureGateway.new(validation: { success: true, raw: "1" })

        event = audit_event_for do
          result = sign
          refute result.success?
          assert_equal :gateway_error, result.error
        end

        assert_empty @esig_gateway.sign_actions
        assert_empty @note_gateway.fetches, "a refused reply never reads the body"
        assert_equal "8", event.outcome
        assert_equal refusal_desc(:gateway_error), event.outcome_desc
        refute_leaks event, SIGNATURE_CODE
      end

      test "a Boolean false validation is an invalid signature code, not a gateway error" do
        @esig_gateway = FakeESignatureGateway.new(validation: false)

        event = audit_event_for do
          result = sign
          assert_equal :invalid_signature_code, result.error
        end

        assert_empty @esig_gateway.sign_actions
        assert_equal "4", event.outcome
        assert_equal refusal_desc(:invalid_signature_code), event.outcome_desc
        refute_leaks event, SIGNATURE_CODE
      end

      # -- refusals (outcome "4") -------------------------------------------

      test "an invalid signature code writes a refusal event and sends no sign action" do
        @esig_gateway = FakeESignatureGateway.new(validation: false)

        event = audit_event_for do
          result = sign
          assert_equal :invalid_signature_code, result.error
        end

        assert_empty @esig_gateway.sign_actions
        assert_empty @note_gateway.fetches, "a refused code never reads the body"
        assert_equal "4", event.outcome
        assert_equal "E", event.action
        assert_equal "application", event.event_type
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
        assert_equal "DocumentReference", event.entity_type
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal refusal_desc(:invalid_signature_code), event.outcome_desc
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
        assert_equal refusal_desc(:no_note), event.outcome_desc
        refute_leaks event, SIGNATURE_CODE
      end

      # An empty or blank body never verifies, so it is never signed.
      {
        "a nil body" => nil,
        "an empty body" => [],
        "a body of blank rows" => [ "", "  " ],
        "a body that is a String, not rows" => NOTE_BODY,
        "a body that is a Hash" => { success: false, raw: nil },
        "a body whose rows are not all Strings" => [ "S: Synthetic row.", 7 ],
        # A row holding a row separator makes the "\n" join ambiguous: two
        # different bodies would hash alike.
        "a body with a line feed inside a row" => [ "S: Synthetic row.\nP: Synthetic smuggled row." ],
        "a body with a carriage return inside a row" => [ "S: Synthetic row.\rP: Synthetic smuggled row." ],
        "a body with a CRLF ending a row" => [ "S: Synthetic row.\r\n", "P: Synthetic plan." ],
        # Bytes that are not text cannot be shown, compared or re-read alike.
        "a body with a row of invalid encoding" => [ "S: Synthetic row.", INVALID_ENCODING_ROW ]
      }.each do |label, body|
        test "#{label} is not signed: note_text_unavailable" do
          @note_gateway.rows = body

          event = audit_event_for do
            result = sign
            refute result.success?
            assert_equal :note_text_unavailable, result.error
          end

          assert_equal [ NOTE_IEN.to_s ], @note_gateway.fetches.map(&:to_s)
          assert_empty @esig_gateway.sign_actions
          assert_equal "4", event.outcome
          assert_equal NOTE_IEN.to_s, event.entity_identifier
          assert_equal refusal_desc(:note_text_unavailable), event.outcome_desc
          refute_match(/sha256/i, event.outcome_desc)
          refute_leaks event, SIGNATURE_CODE
        end
      end

      # -- gateway errors (outcome "8") --------------------------------------

      test "a failed sign action writes a serious-failure event" do
        @esig_gateway = FakeESignatureGateway.new(add_result: { success: false, raw: "0^record locked" })

        event = audit_event_for do
          result = sign
          assert_equal :gateway_error, result.error
        end

        assert_equal [ NOTE_IEN.to_s ], @note_gateway.fetches.map(&:to_s),
                     "a sign action that failed filed nothing, so there is no record to read back"
        assert_equal "8", event.outcome
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal refusal_desc(:gateway_error), event.outcome_desc
        refute_match(/sha256/i, event.outcome_desc)
        refute_leaks event, SIGNATURE_CODE
      end

      test "a nil validation reply writes a serious-failure event and sends no sign action" do
        @esig_gateway = FakeESignatureGateway.new(validation: nil)

        event = audit_event_for do
          result = sign
          assert_equal :gateway_error, result.error
        end

        assert_empty @esig_gateway.sign_actions
        assert_equal "8", event.outcome
        assert_equal refusal_desc(:gateway_error), event.outcome_desc
        refute_leaks event, SIGNATURE_CODE
      end

      test "a String validation reply is a gateway error, however truthy it looks" do
        @esig_gateway = FakeESignatureGateway.new(validation: "1")

        event = audit_event_for do
          result = sign
          assert_equal :gateway_error, result.error
        end

        assert_empty @esig_gateway.sign_actions
        assert_equal "8", event.outcome
        assert_equal refusal_desc(:gateway_error), event.outcome_desc
      end

      # -- a gateway that raises still leaves a row --------------------------

      test "validate raising writes a gateway_exception event and re-raises the same exception" do
        boom = GatewayDown.new(GATEWAY_DOWN_MESSAGE)
        @esig_gateway = FakeESignatureGateway.new(validate_error: boom)

        event = audit_event_for do
          raised = assert_raises(GatewayDown) { sign }
          assert_same boom, raised
        end

        assert_empty @esig_gateway.sign_actions
        assert_equal "8", event.outcome
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
        assert_equal refusal_desc(:gateway_exception), event.outcome_desc
        refute_leaks event, GATEWAY_DOWN_MESSAGE
        refute_leaks event, SIGNATURE_CODE
      end

      test "fetch_body raising writes a gateway_exception event and re-raises the same exception" do
        boom = GatewayDown.new(GATEWAY_DOWN_MESSAGE)
        @note_gateway = FakeNoteGateway.new(rows: NOTE_ROWS.dup, error: boom)

        event = audit_event_for do
          raised = assert_raises(GatewayDown) { sign }
          assert_same boom, raised
        end

        assert_equal [ NOTE_IEN.to_s ], @note_gateway.fetches.map(&:to_s)
        assert_empty @esig_gateway.sign_actions
        assert_equal "8", event.outcome
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal refusal_desc(:gateway_exception), event.outcome_desc
        refute_leaks event, GATEWAY_DOWN_MESSAGE
        refute_leaks event, SIGNATURE_CODE
      end

      # The RPC may have filed before the call died, so the row does not
      # claim the note is unsigned.
      test "add raising writes a sign_outcome_unknown event and re-raises the same exception" do
        boom = GatewayDown.new(GATEWAY_DOWN_MESSAGE)
        @esig_gateway = FakeESignatureGateway.new(add_error: boom)

        event = audit_event_for do
          raised = assert_raises(GatewayDown) { sign }
          assert_same boom, raised
        end

        assert_equal 1, @esig_gateway.sign_actions.size
        assert_equal [ NOTE_IEN.to_s ], @note_gateway.fetches.map(&:to_s)
        assert_equal "8", event.outcome
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal refusal_desc(:sign_outcome_unknown), event.outcome_desc
        refute_match(/sha256/i, event.outcome_desc)
        refute_leaks event, GATEWAY_DOWN_MESSAGE
        refute_leaks event, SIGNATURE_CODE
      end

      # -- the actor must be the signer --------------------------------------

      test "an attributed actor who is not the author is refused before validation" do
        AuditContext.agent_resolver = -> { { agent_who_type: "Practitioner", agent_who_identifier: "9999" } }

        event = audit_event_for do
          result = sign
          refute result.success?
          assert_equal :actor_mismatch, result.error
        end

        assert_empty @esig_gateway.validations
        assert_empty @esig_gateway.sign_actions
        assert_equal "4", event.outcome
        assert_equal "Practitioner", event.agent_who_type
        assert_equal "9999", event.agent_who_identifier
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal refusal_desc(:actor_mismatch), event.outcome_desc
        refute_leaks event, SIGNATURE_CODE
      end

      test "an attributed actor with the author's number but another type is refused" do
        AuditContext.agent_resolver = -> { { agent_who_type: "Patient", agent_who_identifier: AUTHOR_DUZ.to_s } }

        event = audit_event_for do
          assert_equal :actor_mismatch, sign.error
        end

        assert_empty @esig_gateway.validations
        assert_empty @esig_gateway.sign_actions
        assert_equal "4", event.outcome
        assert_equal "Patient", event.agent_who_type
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
      end

      test "an attributed Practitioner who is the author signs normally" do
        AuditContext.agent_resolver = -> { { agent_who_type: "Practitioner", agent_who_identifier: AUTHOR_DUZ.to_s } }

        event = audit_event_for do
          result = sign
          assert result.success?, "signing failed: #{result.error.inspect}"
        end

        assert_equal 1, @esig_gateway.sign_actions.size
        assert_equal "0", event.outcome
        assert_equal "Practitioner", event.agent_who_type
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
        assert_equal success_desc(NOTE_ROWS), event.outcome_desc
      end

      test "with no attributed identity the actor is the author" do
        assert_nil AuditContext.agent_attributes[:agent_who_identifier]

        event = audit_event_for do
          assert sign.success?
        end

        assert_equal "Practitioner", event.agent_who_type
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
      end

      # Only agent_who_type, agent_who_identifier and agent_name pass from the
      # resolver to the row. Anything else it returns could overwrite the
      # outcome or raise on an unknown column.
      test "extra keys from the resolver do not change a success event or make it raise" do
        AuditContext.agent_resolver = -> { resolved_agent_with_extras }

        event = audit_event_for do
          result = assert_nothing_raised { sign }
          assert result.success?, "signing failed: #{result.error.inspect}"
        end

        assert_equal "0", event.outcome
        assert_equal success_desc(NOTE_ROWS), event.outcome_desc
        assert_equal "Practitioner", event.agent_who_type
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
        assert_equal "PROVIDER,SYNTHETIC", event.agent_name
        assert_equal "E", event.action
        assert_equal "DocumentReference", event.entity_type
        assert_equal NOTE_IEN.to_s, event.entity_identifier
      end

      test "extra keys from the resolver do not turn a refusal into a success" do
        AuditContext.agent_resolver = -> { resolved_agent_with_extras }
        @esig_gateway = FakeESignatureGateway.new(validation: false)

        event = audit_event_for do
          result = assert_nothing_raised { sign }
          assert_equal :invalid_signature_code, result.error
        end

        assert_equal "4", event.outcome
        assert_equal refusal_desc(:invalid_signature_code), event.outcome_desc
        assert_equal "Practitioner", event.agent_who_type
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
        assert_equal "PROVIDER,SYNTHETIC", event.agent_name
        assert_equal "E", event.action
        assert_equal NOTE_IEN.to_s, event.entity_identifier
      end

      # Inside an audited request the actor is known or the request is not
      # trusted: the author is assumed only where there is no request at all.
      test "an unattributed sign inside an audited request is refused before validation" do
        AuditContext.inside_audited_request = true
        assert_nil AuditContext.agent_attributes[:agent_who_identifier]

        event = audit_event_for do
          result = sign
          refute result.success?
          assert_equal :actor_mismatch, result.error
        end

        assert_empty @esig_gateway.validations
        assert_empty @esig_gateway.sign_actions
        assert_empty @note_gateway.fetches
        assert_equal "4", event.outcome
        assert_equal "Unknown", event.agent_who_type
        assert_nil event.agent_who_identifier
        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal refusal_desc(:actor_mismatch), event.outcome_desc
        refute_leaks event, SIGNATURE_CODE
      end

      test "a resolver with no identifier inside an audited request is refused the same way" do
        AuditContext.inside_audited_request = true
        AuditContext.agent_resolver = -> { { agent_who_type: "Practitioner", agent_who_identifier: nil } }

        event = audit_event_for do
          assert_equal :actor_mismatch, sign.error
        end

        assert_empty @esig_gateway.validations
        assert_empty @esig_gateway.sign_actions
        assert_equal "4", event.outcome
        assert_equal "Unknown", event.agent_who_type
        assert_nil event.agent_who_identifier
      end

      test "an attributed author inside an audited request signs normally" do
        AuditContext.inside_audited_request = true
        AuditContext.agent_resolver = -> { { agent_who_type: "Practitioner", agent_who_identifier: AUTHOR_DUZ.to_s } }

        event = audit_event_for do
          result = sign
          assert result.success?, "signing failed: #{result.error.inspect}"
        end

        assert_equal "0", event.outcome
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
      end

      # -- the author must be a DUZ ------------------------------------------

      {
        "a nil author" => nil,
        "an author carrying statement syntax" => "12; DROP"
      }.each do |label, bad_duz|
        test "#{label} is invalid input, refused before validation, with an Unknown agent" do
          event = audit_event_for do
            result = assert_nothing_raised { sign(author_duz: bad_duz) }
            refute result.success?
            assert_equal :invalid_input, result.error
          end

          assert_empty @esig_gateway.validations
          assert_empty @esig_gateway.sign_actions
          assert_empty @note_gateway.fetches
          assert_equal "4", event.outcome
          assert_equal "Unknown", event.agent_who_type
          assert_nil event.agent_who_identifier
          assert_equal refusal_desc(:invalid_input), event.outcome_desc
          unless bad_duz.nil?
            refute_leaks event, bad_duz
            refute_leaks event, "DROP"
          end
          refute_leaks event, SIGNATURE_CODE
        end
      end

      test "a digit-string author signs like the Integer form" do
        event = audit_event_for do
          result = sign(author_duz: AUTHOR_DUZ.to_s)
          assert result.success?, "signing failed: #{result.error.inspect}"
        end

        assert_equal "Practitioner", event.agent_who_type
        assert_equal AUTHOR_DUZ.to_s, event.agent_who_identifier
      end

      # -- identifiers are validated before they reach the row ---------------

      {
        "a nil patient" => nil,
        "a patient carrying row syntax" => "5; content-sha256 aaaa",
        "a non-numeric patient" => "87x91"
      }.each do |label, bad_dfn|
        test "#{label} is invalid input and never reaches the row" do
          event = audit_event_for do
            result = sign(dfn: bad_dfn)
            refute result.success?
            assert_equal :invalid_input, result.error
          end

          assert_empty @esig_gateway.validations
          assert_empty @esig_gateway.sign_actions
          assert_equal "4", event.outcome
          assert_equal "progress_note_sign_refused; patient none; reason invalid_input", event.outcome_desc
          refute_leaks event, bad_dfn unless bad_dfn.nil?
          refute_leaks event, "sha256"
          refute_leaks event, SIGNATURE_CODE
        end
      end

      test "a note IEN that is not all digits is invalid input, with no entity identifier" do
        event = audit_event_for do
          result = assert_nothing_raised { sign(note_ien: "12/34") }
          refute result.success?
          assert_equal :invalid_input, result.error
        end

        assert_empty @esig_gateway.validations
        assert_empty @esig_gateway.sign_actions
        assert_empty @note_gateway.fetches
        assert_equal "4", event.outcome
        assert_equal "DocumentReference", event.entity_type
        assert_nil event.entity_identifier
        assert_nil event.entity_id
        assert_equal refusal_desc(:invalid_input), event.outcome_desc
        refute_leaks event, "12/34"
        refute_leaks event, SIGNATURE_CODE
      end

      test "a digit-string patient and note IEN sign like their Integer forms" do
        event = audit_event_for do
          result = sign(dfn: DFN.to_s, note_ien: NOTE_IEN.to_s)
          assert result.success?, "signing failed: #{result.error.inspect}"
        end

        assert_equal NOTE_IEN.to_s, event.entity_identifier
        assert_equal success_desc(NOTE_ROWS), event.outcome_desc
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

      # The documented residual: by the time the success row is written the
      # signature already exists in RPMS, so the caller gets the exception.
      test "sign raises when the success event cannot be written, after the sign action was sent" do
        with_failing_audit_write do
          error = assert_raises(ActiveRecord::StatementInvalid) { sign }
          assert_equal "audit down", error.message
        end
        assert_equal 1, @esig_gateway.sign_actions.size, "the sign action was sent before the audit write failed"
      end

      test "a refused signing raises too when the audit event cannot be written, and sends no sign action" do
        @esig_gateway = FakeESignatureGateway.new(validation: false)

        with_failing_audit_write do
          assert_raises(ActiveRecord::StatementInvalid) { sign }
        end
        assert_empty @esig_gateway.sign_actions
      end

      private

      def service(dfn: DFN, author_duz: AUTHOR_DUZ)
        ProgressNoteService.new(
          dfn: dfn, visit_ien: VISIT_IEN, author_duz: author_duz,
          gateway: @note_gateway, esignature_gateway: @esig_gateway
        )
      end

      def sign(note_ien: NOTE_IEN, signature_code: SIGNATURE_CODE, dfn: DFN, author_duz: AUTHOR_DUZ)
        service(dfn: dfn, author_duz: author_duz).sign(note_ien: note_ien, signature_code: signature_code)
      end

      # The author, attributed, with keys no resolver should be able to pass
      # through to the row.
      def resolved_agent_with_extras
        { agent_who_type: "Practitioner", agent_who_identifier: AUTHOR_DUZ.to_s, agent_name: "PROVIDER,SYNTHETIC",
          outcome: "0", outcome_desc: "x", bogus: 1 }
      end

      # +rows+ is the body read before signing; +record_rows+ the body read
      # after it, the same rows unless the fake was told otherwise.
      def success_desc(rows, record_rows = rows, dfn: DFN)
        "#{content_desc(rows, dfn: dfn)}; " \
          "record-sha256 #{Digest::SHA256.hexdigest(record_rows.join("\n"))}; record-rows #{record_rows.size}"
      end

      def unavailable_desc(rows, dfn: DFN)
        "#{content_desc(rows, dfn: dfn)}; record-sha256 unavailable"
      end

      def content_desc(rows, dfn: DFN)
        "progress_note_signed; patient #{dfn}; " \
          "content-sha256 #{Digest::SHA256.hexdigest(rows.join("\n"))}; content-rows #{rows.size}"
      end

      def refusal_desc(reason, patient: DFN)
        "progress_note_sign_refused; patient #{patient}; reason #{reason}"
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

      def content_rows(event)
        event.outcome_desc[/content-rows (\d+)(;|\z)/, 1]&.to_i
      end

      def record_hash(event)
        event.outcome_desc[/record-sha256 ([0-9a-f]{64})/, 1]
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
