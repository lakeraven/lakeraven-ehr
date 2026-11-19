# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # ProgressNoteService#create_and_sign and the Part 2 label (#906). The
    # chart only ever calls create_and_sign, so every Result it returns once
    # the note exists must say what happened to the label: a :label_failed on
    # a signed note must not be invisible. Synthetic identifiers throughout.
    class ProgressNoteServiceCreateAndSignPart2Test < ActiveSupport::TestCase
      DFN = "1001"
      VISIT_IEN = "2090061"
      DUZ = "99999"
      TITLE_IEN = 4321
      NOTE_IEN = 70001
      CODE = "SYNTH-SIG-CODE-906"

      SUD_TEXT = "Counselled on alcohol use disorder."
      CLEAN_TEXT = "Seen for follow-up. Vitals stable."

      class FakeNoteGateway
        def create(_dfn, _visit_ien, _title_ien) = { success: true, ien: NOTE_IEN, raw: NOTE_IEN.to_s }
        def update_text(_note_ien, _text) = { success: true, raw: "0" }
      end

      # Answers as ESignatureGateway does: validate true, which_action a
      # symbol or nil, add a hash.
      class FakeESignatureGateway
        attr_reader :added

        def initialize(which_action: :sign, add: { success: true, raw: "0" })
          @which_action = which_action
          @add = add
          @added = false
        end

        def validate(_duz, _code) = true
        def which_action(_note_ien, _duz) = @which_action

        def add(_note_ien, _duz, _code, action: :sign)
          @added = true
          @add
        end
      end

      def create_and_sign(text, esignature = FakeESignatureGateway.new)
        ProgressNoteService
          .new(dfn: DFN, visit_ien: VISIT_IEN, author_duz: DUZ,
               gateway: FakeNoteGateway.new, esignature_gateway: esignature)
          .create_and_sign(title_ien: TITLE_IEN, text: text, signature_code: CODE)
      end

      def note_labels
        Part2Label.where(record_type: "tiu_note", record_id: NOTE_IEN.to_s)
      end

      def with_raising_mark(error)
        restore = singleton_method_restore(Part2Label, :mark!)
        Part2Label.define_singleton_method(:mark!) { |*_args, **_kwargs| raise error }
        yield
      ensure
        restore&.call
      end

      test "suspected text signed successfully reports the label as labelled" do
        result = create_and_sign(SUD_TEXT)

        assert result.success?, "error: #{result.error.inspect}"
        assert_equal NOTE_IEN, result.note_ien
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count
        assert_equal "42CFRPart2", note_labels.first.security_code
      end

      test "suspected text the author may only cosign fails at sign_action and still reports the label" do
        esignature = FakeESignatureGateway.new(which_action: :cosign)

        result = create_and_sign(SUD_TEXT, esignature)

        refute result.success?
        assert_equal :sign_action, result.stage
        assert_equal :sign_not_permitted, result.error
        assert_equal NOTE_IEN, result.note_ien
        assert_equal false, esignature.added
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count
      end

      test "suspected text whose signing is refused fails at sign and still reports the label" do
        esignature = FakeESignatureGateway.new(add: { success: false, raw: "89250005^refused" })

        result = create_and_sign(SUD_TEXT, esignature)

        refute result.success?
        assert_equal :sign, result.stage
        assert_equal :gateway_error, result.error
        assert_equal NOTE_IEN, result.note_ien
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count
      end

      test "a failed label write on a note that is then signed is reported as label_failed" do
        result = nil
        with_raising_mark(ActiveRecord::StatementInvalid.new("synthetic: label write failed")) do
          result = create_and_sign(SUD_TEXT)
        end

        assert result.success?, "the note is signed whatever happened to the label: #{result.error.inspect}"
        assert_equal NOTE_IEN, result.note_ien
        assert_equal :label_failed, result.part2_label
        assert_equal 0, note_labels.count
      end

      test "a failed label write on a note the author may not sign is reported as label_failed" do
        result = nil
        with_raising_mark(ActiveRecord::StatementInvalid.new("synthetic: label write failed")) do
          result = create_and_sign(SUD_TEXT, FakeESignatureGateway.new(which_action: nil))
        end

        refute result.success?
        assert_equal :sign_action, result.stage
        assert_equal :label_failed, result.part2_label
      end

      test "clean text signed successfully reports not_suspected and writes no label" do
        result = create_and_sign(CLEAN_TEXT)

        assert result.success?, "error: #{result.error.inspect}"
        assert_equal :not_suspected, result.part2_label
        assert_equal 0, Part2Label.count
      end
    end
  end
end
