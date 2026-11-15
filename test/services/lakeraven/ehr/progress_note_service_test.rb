# frozen_string_literal: true

require "test_helper"

# ProgressNoteService#create and the Part 2 label (#906, slice of #522).
# Incidental substance-use content in a progress note is LABELLED, never
# blocked: the note always reaches the gateway. The label is written before
# the note text, and a failed label write does not stop the note (read-time
# Part2Posture covers the gap). Synthetic identifiers throughout.
module Lakeraven
  module EHR
    class ProgressNoteServiceTest < ActiveSupport::TestCase
      DFN = 9001
      VISIT_IEN = 2090061
      AUTHOR_DUZ = 301
      TITLE_IEN = 4321
      NOTE_IEN = 70001

      SUD_TEXT = "Client reports drinking nightly since the layoff; discussed coping skills."
      CLEAN_TEXT = "Discussed sleep hygiene and work stress; PHQ-9 reviewed."

      # Injected in place of ProgressNoteGateway. Records every call, and at
      # update_text time records whether the label row was already there.
      class FakeNoteGateway
        attr_reader :calls, :label_present_at_update_text

        def initialize(returns: {})
          @returns = returns
          @calls = []
          @label_present_at_update_text = nil
        end

        def create(dfn, visit_ien, title_ien)
          @calls << { method: :create, args: [ dfn, visit_ien, title_ien ] }
          @returns.fetch(:create) { { success: true, ien: NOTE_IEN, raw: NOTE_IEN.to_s } }
        end

        def update_text(note_ien, text)
          @calls << { method: :update_text, args: [ note_ien, text ] }
          @label_present_at_update_text =
            Part2Label.where(record_type: "tiu_note", record_id: note_ien.to_s).count.positive?
          @returns.fetch(:update_text) { { success: true, raw: "0" } }
        end

        def methods_called = @calls.map { |c| c[:method] }
      end

      def service(gateway, dfn: DFN, visit_ien: VISIT_IEN)
        ProgressNoteService.new(dfn: dfn, visit_ien: visit_ien, author_duz: AUTHOR_DUZ, gateway: gateway)
      end

      def note_labels
        Part2Label.where(record_type: "tiu_note", record_id: NOTE_IEN.to_s)
      end

      def with_raising_stub(klass, method_name, error)
        restore = singleton_method_restore(klass, method_name)
        klass.define_singleton_method(method_name) { |*_args, **_kwargs| raise error }
        yield
      ensure
        restore&.call
      end

      # Makes every regex match issued from sud_content_suspicion.rb raise
      # Regexp::TimeoutError for the block, however many patterns there are
      # and whichever match method is used. Matches issued from anywhere else
      # (ActiveRecord, the logger) are untouched. Yields an Array that
      # collects one entry per raise.
      REGEX_MATCH_METHODS = %i[match? match =~ === scan index].freeze

      def with_sud_regex_timeout
        fired = []
        trace = TracePoint.new(:c_call) do |tp|
          next unless REGEX_MATCH_METHODS.include?(tp.method_id)
          next unless tp.defined_class == Regexp || tp.defined_class == String
          next unless tp.path.to_s.end_with?("sud_content_suspicion.rb")

          fired << tp.method_id
          raise Regexp::TimeoutError, "synthetic: regex match timed out"
        end
        trace.enable { yield fired }
      end

      # Swaps Rails.logger for one that writes "SEVERITY message" lines to a
      # StringIO for the block, and puts the original back after.
      def with_captured_log
        original = Rails.logger
        io = StringIO.new
        logger = ActiveSupport::Logger.new(io)
        logger.level = Logger::DEBUG
        logger.formatter = proc { |severity, _time, _progname, message| "#{severity} #{message}\n" }
        Rails.logger = logger
        yield io
      ensure
        Rails.logger = original
      end

      # --- SUD content is labelled, not blocked ---

      test "substance-use text is not blocked: the gateway receives the exact text" do
        gateway = FakeNoteGateway.new

        result = service(gateway).create(title_ien: TITLE_IEN, text: SUD_TEXT)

        assert result.success?
        assert_equal NOTE_IEN, result.note_ien
        assert_equal %i[create update_text], gateway.methods_called
        assert_equal [ DFN, VISIT_IEN, TITLE_IEN ], gateway.calls[0][:args]
        assert_equal [ NOTE_IEN, SUD_TEXT ], gateway.calls[1][:args]
        assert_equal :labelled, result.part2_label
      end

      test "suspected text leaves a Part 2 label row for the note" do
        result = service(FakeNoteGateway.new).create(title_ien: TITLE_IEN, text: SUD_TEXT)

        assert result.success?
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count
        row = note_labels.first
        assert_equal "tiu_note", row.record_type
        assert_equal NOTE_IEN.to_s, row.record_id
        assert_equal DFN.to_s, row.patient_dfn
        assert_equal "42CFRPart2", row.security_code
      end

      test "unclassified text (nil) is labelled and still written" do
        gateway = FakeNoteGateway.new

        result = service(gateway).create(title_ien: TITLE_IEN, text: nil)

        assert result.success?
        assert_equal %i[create update_text], gateway.methods_called
        assert_equal [ NOTE_IEN, nil ], gateway.calls[1][:args]
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count
        assert_equal "42CFRPart2", note_labels.first.security_code
        assert_equal DFN.to_s, note_labels.first.patient_dfn
      end

      # Blank text is absence of data, not evidence the note is clean.
      test "blank text is labelled and still written" do
        gateway = FakeNoteGateway.new

        result = service(gateway).create(title_ien: TITLE_IEN, text: "")

        assert result.success?
        assert_equal %i[create update_text], gateway.methods_called
        assert_equal [ NOTE_IEN, "" ], gateway.calls[1][:args]
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count
        assert_equal "42CFRPart2", note_labels.first.security_code
      end

      # Text that cannot be read must not stop the note or escape as an
      # exception: it is labelled and written exactly as given.
      test "text with an invalid byte sequence is labelled and still written" do
        gateway = FakeNoteGateway.new
        text = "Pt seen today, caf\xE9".dup.force_encoding("UTF-8")
        refute text.valid_encoding?
        result = nil

        assert_nothing_raised do
          result = service(gateway).create(title_ien: TITLE_IEN, text: text)
        end

        assert result.success?
        assert_equal %i[create update_text], gateway.methods_called
        assert_equal NOTE_IEN, gateway.calls[1][:args][0]
        assert_same text, gateway.calls[1][:args][1]
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count
      end

      test "text in a non-ASCII-compatible encoding is labelled and still written" do
        gateway = FakeNoteGateway.new
        text = "sleep hygiene".encode("UTF-16LE")
        result = nil

        assert_nothing_raised do
          result = service(gateway).create(title_ien: TITLE_IEN, text: text)
        end

        assert result.success?
        assert_equal %i[create update_text], gateway.methods_called
        assert_same text, gateway.calls[1][:args][1]
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count
      end

      test "a string dfn is stored as given" do
        result = service(FakeNoteGateway.new, dfn: "9001").create(title_ien: TITLE_IEN, text: SUD_TEXT)

        assert_equal :labelled, result.part2_label
        assert_equal "9001", note_labels.first.patient_dfn
      end

      test "clean text writes no label" do
        gateway = FakeNoteGateway.new

        result = service(gateway).create(title_ien: TITLE_IEN, text: CLEAN_TEXT)

        assert result.success?
        assert_equal [ NOTE_IEN, CLEAN_TEXT ], gateway.calls[1][:args]
        assert_equal :not_suspected, result.part2_label
        assert_equal 0, Part2Label.count
      end

      # --- the label is written before the note text ---

      test "the label row exists before update_text reaches the gateway" do
        gateway = FakeNoteGateway.new

        service(gateway).create(title_ien: TITLE_IEN, text: SUD_TEXT)

        assert_equal true, gateway.label_present_at_update_text
      end

      test "when update_text fails for suspected text the result fails and the label stays" do
        gateway = FakeNoteGateway.new(returns: { update_text: { success: false, raw: "-1^synthetic failure" } })

        result = service(gateway).create(title_ien: TITLE_IEN, text: SUD_TEXT)

        refute result.success?
        assert_equal :gateway_error, result.error
        assert_equal %i[create update_text], gateway.methods_called
        assert_equal 1, note_labels.count
        assert_equal "42CFRPart2", note_labels.first.security_code
      end

      # --- a failed label write does not block the note ---

      test "a failing label write does not block the note" do
        gateway = FakeNoteGateway.new
        svc = service(gateway)
        result = nil

        with_raising_stub(Part2Label, :mark!, ActiveRecord::ActiveRecordError.new("synthetic: label write failed")) do
          assert_nothing_raised do
            result = svc.create(title_ien: TITLE_IEN, text: SUD_TEXT)
          end
        end

        assert result.success?
        assert_equal NOTE_IEN, result.note_ien
        assert_equal %i[create update_text], gateway.methods_called
        assert_equal [ NOTE_IEN, SUD_TEXT ], gateway.calls[1][:args]
        assert_equal :label_failed, result.part2_label
        assert_equal 0, note_labels.count
      end

      test "after a failed label write the note still reads as Part 2" do
        svc = service(FakeNoteGateway.new)
        result = nil

        with_raising_stub(Part2Label, :mark!, ActiveRecord::ActiveRecordError.new("synthetic: label write failed")) do
          result = svc.create(title_ien: TITLE_IEN, text: SUD_TEXT)
        end

        assert_equal :label_failed, result.part2_label
        assert_equal true,
          Part2Posture.part2?(record_type: "tiu_note", record_id: result.note_ien, content: SUD_TEXT)
      end

      # --- a failed label write is not silent (#906 round 3) ---
      # The warning names the error class and the note, so the gap can be
      # found and repaired. It never carries the note text.

      test "a failing label write logs a warning naming the error class and the note ien, without the note text" do
        svc = service(FakeNoteGateway.new)
        result = nil
        logged = nil

        with_captured_log do |io|
          with_raising_stub(Part2Label, :mark!, ActiveRecord::StatementInvalid.new("synthetic: label write failed")) do
            result = svc.create(title_ien: TITLE_IEN, text: SUD_TEXT)
          end
          logged = io.string
        end

        assert result.success?
        assert_equal :label_failed, result.part2_label

        warnings = logged.lines.select { |line| line.start_with?("WARN") }
        named = warnings.select { |line| line.include?("ActiveRecord::StatementInvalid") && line.include?(NOTE_IEN.to_s) }
        refute_empty named,
          "expected a WARN line naming ActiveRecord::StatementInvalid and note #{NOTE_IEN}; logged: #{warnings.length} WARN line(s)"
        refute_includes logged, SUD_TEXT
        refute_includes logged, "drinking nightly"
      end

      test "a successful label write logs no warning" do
        logged = nil

        with_captured_log do |io|
          service(FakeNoteGateway.new).create(title_ien: TITLE_IEN, text: SUD_TEXT)
          logged = io.string
        end

        assert_empty logged.lines.select { |line| line.start_with?("WARN") }
        refute_includes logged, SUD_TEXT
      end

      # --- the text cannot be classified in time (#906 round 3) ---
      # A regex timeout must not stop the note or escape as an exception:
      # the note is labelled and written exactly as given.

      test "a regex timeout while reading the text labels the note and still writes it" do
        gateway = FakeNoteGateway.new
        result = nil

        with_sud_regex_timeout do |fired|
          assert_nothing_raised do
            result = service(gateway).create(title_ien: TITLE_IEN, text: CLEAN_TEXT)
          end
          refute_empty fired, "the synthetic regex timeout never fired"
        end

        assert result.success?
        assert_equal %i[create update_text], gateway.methods_called
        assert_equal [ NOTE_IEN, CLEAN_TEXT ], gateway.calls[1][:args]
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count
        assert_equal true, gateway.label_present_at_update_text
      end

      # --- text the pattern used to miss is labelled (#906 round 3) ---

      { "invisible characters only" => "\u200B",
        "an underscore-joined phrase" => "substance_use: yes",
        "a bare drug mention" => "Pt admits to using drugs." }.each do |name, text|
        test "text that is #{name} is labelled and still written" do
          gateway = FakeNoteGateway.new

          result = service(gateway).create(title_ien: TITLE_IEN, text: text)

          assert result.success?
          assert_equal [ NOTE_IEN, text ], gateway.calls[1][:args]
          assert_equal :labelled, result.part2_label
          assert_equal 1, note_labels.count
        end
      end

      # --- existing failure paths write no label ---

      test "a nil dfn is invalid input, reaches no gateway and writes no label" do
        gateway = FakeNoteGateway.new

        result = service(gateway, dfn: nil).create(title_ien: TITLE_IEN, text: SUD_TEXT)

        refute result.success?
        assert_equal :invalid_input, result.error
        assert_empty gateway.calls
        assert_equal 0, Part2Label.count
      end

      test "a nil title is missing_title, reaches no gateway and writes no label" do
        gateway = FakeNoteGateway.new

        result = service(gateway).create(title_ien: nil, text: SUD_TEXT)

        refute result.success?
        assert_equal :missing_title, result.error
        assert_empty gateway.calls
        assert_equal 0, Part2Label.count
      end

      test "a failing create writes no label and no text" do
        gateway = FakeNoteGateway.new(returns: { create: { success: false, ien: nil, raw: nil } })

        result = service(gateway).create(title_ien: TITLE_IEN, text: SUD_TEXT)

        refute result.success?
        assert_equal :gateway_error, result.error
        assert_equal %i[create], gateway.methods_called
        assert_equal 0, Part2Label.count
      end
    end
  end
end
