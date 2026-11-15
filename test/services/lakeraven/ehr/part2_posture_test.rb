# frozen_string_literal: true

require "test_helper"

# Part2Posture.part2? is the "never the reverse" rule of #906 (slice of
# #522): a record is Part 2 unless there is positive reason to say it is
# not. The ONLY false case is: the record can be looked up, it has no label
# row at all, and its content reads clean. Synthetic identifiers throughout.
module Lakeraven
  module EHR
    class Part2PostureTest < ActiveSupport::TestCase
      CLEAN = "Discussed sleep hygiene."
      SUSPECTED = "Client reports drinking most evenings."
      RECORD = { record_type: "tiu_note", record_id: "70001" }.freeze

      # A label row with an arbitrary security_code. update_column puts the
      # code in the table whether or not the model validates the value.
      def label_with_code(code, record_id: "70001")
        Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: record_id)
        row = Part2Label.find_by!(record_type: "tiu_note", record_id: record_id)
        row.update_column(:security_code, code)
        assert_equal code, Part2Label.find_by!(record_type: "tiu_note", record_id: record_id).security_code
        row
      end

      # Make a singleton method raise for the block; put the original back after.
      def with_raising_stub(klass, method_name, error)
        restore = singleton_method_restore(klass, method_name)
        klass.define_singleton_method(method_name) { |*_args, **_kwargs| raise error }
        yield
      ensure
        restore&.call
      end

      # --- a label exists ---

      test "a 42CFRPart2 label makes a record Part 2 even when its content is clean" do
        Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "70001")

        assert_equal true, Part2Posture.part2?(**RECORD, content: CLEAN)
      end

      # THE DONE CRITERION of #906.
      test "an unknown label counts as Part 2" do
        label_with_code("XYZ-unknown")

        assert_equal true, Part2Posture.part2?(**RECORD, content: CLEAN)
      end

      %w[R N XYZ-unknown].each do |code|
        test "an unknown label #{code.inspect} counts as Part 2 with clean content" do
          label_with_code(code)

          assert_equal true, Part2Posture.part2?(**RECORD, content: CLEAN)
        end
      end

      test "an unknown label counts as Part 2 with empty content" do
        label_with_code("XYZ-unknown")

        assert_equal true, Part2Posture.part2?(**RECORD, content: "")
      end

      # --- no label ---

      test "unlabelled but suspected content is Part 2" do
        assert_equal 0, Part2Label.count
        assert_equal true, Part2Posture.part2?(**RECORD, content: SUSPECTED)
      end

      test "unlabelled nil content is Part 2" do
        assert_equal 0, Part2Label.count
        assert_equal true, Part2Posture.part2?(**RECORD, content: nil)
      end

      test "unlabelled Hash content is Part 2" do
        assert_equal 0, Part2Label.count
        assert_equal true, Part2Posture.part2?(**RECORD, content: { text: CLEAN })
      end

      # Blank content is absence of data, not evidence the record is clean.
      test "unlabelled empty content is Part 2" do
        assert_equal 0, Part2Label.count
        assert_equal true, Part2Posture.part2?(**RECORD, content: "")
      end

      test "unlabelled whitespace-only content is Part 2" do
        assert_equal 0, Part2Label.count
        assert_equal true, Part2Posture.part2?(**RECORD, content: " \n")
      end

      # Content that cannot be read is Part 2, and reading it does not raise.
      test "unlabelled content with an invalid byte sequence is Part 2 and does not raise" do
        content = "Pt seen today, caf\xE9".dup.force_encoding("UTF-8")
        refute content.valid_encoding?
        assert_equal 0, Part2Label.count

        result = nil
        assert_nothing_raised { result = Part2Posture.part2?(**RECORD, content: content) }
        assert_equal true, result
      end

      test "unlabelled content in a non-ASCII-compatible encoding is Part 2 and does not raise" do
        content = "sleep hygiene".encode("UTF-16LE")
        assert_equal 0, Part2Label.count

        result = nil
        assert_nothing_raised { result = Part2Posture.part2?(**RECORD, content: content) }
        assert_equal true, result
      end

      test "unlabelled clean content is not Part 2 - the only false case" do
        assert_equal 0, Part2Label.count
        assert_equal false, Part2Posture.part2?(**RECORD, content: CLEAN)
      end

      test "a label on a different record does not make a clean record Part 2" do
        Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "70002")

        assert_equal false, Part2Posture.part2?(**RECORD, content: CLEAN)
        assert_equal true, Part2Posture.part2?(record_type: "tiu_note", record_id: "70002", content: CLEAN)
      end

      test "an integer record id finds the label stored under its string form" do
        Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "70001")

        assert_equal true, Part2Posture.part2?(record_type: "tiu_note", record_id: 70001, content: CLEAN)
      end

      # --- the lookup normalises ids the same way the write does ---
      # Surrounding whitespace is stripped from record_type and record_id,
      # and record_type is case-insensitive (stored lower-case).

      { "a leading space in record_id" => { record_type: "tiu_note", record_id: " 70003" },
        "a trailing newline in record_id" => { record_type: "tiu_note", record_id: "70003\n" },
        "an upper-case record_type" => { record_type: "TIU_NOTE", record_id: "70003" },
        "a trailing space in record_type" => { record_type: "tiu_note ", record_id: "70003" } }.each do |name, record|
        test "#{name} still finds the label" do
          Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "70003")
          assert_equal 1, Part2Label.where(record_type: "tiu_note", record_id: "70003").count

          assert_equal true, Part2Posture.part2?(**record, content: CLEAN)
        end
      end

      # --- the record cannot be looked up: fail closed ---

      [ nil, "", "  " ].each do |blank|
        test "a #{blank.inspect} record_type is Part 2 regardless of content" do
          assert_equal true, Part2Posture.part2?(record_type: blank, record_id: "70001", content: CLEAN)
        end

        test "a #{blank.inspect} record_id is Part 2 regardless of content" do
          assert_equal true, Part2Posture.part2?(record_type: "tiu_note", record_id: blank, content: CLEAN)
        end
      end

      # --- the label lookup fails: fail closed ---

      # The seam asserted on is Part2Label.exists? (the class method), so the
      # posture must look the label up through it.
      test "a failing label lookup is Part 2, not an exception, even for clean content" do
        # Reference the constants first so a missing class fails here, not in the stub helper.
        posture = Part2Posture
        error = ActiveRecord::StatementInvalid.new("synthetic: label table unreachable")

        with_raising_stub(Part2Label, :exists?, error) do
          result = nil
          assert_nothing_raised do
            result = posture.part2?(**RECORD, content: CLEAN)
          end
          assert_equal true, result
        end
      end

      test "the label lookup goes through Part2Label.exists?" do
        Part2Posture # fail on the missing class before stubbing
        with_recording_stub(Part2Label, :exists?, false) do |calls|
          assert_equal false, Part2Posture.part2?(**RECORD, content: CLEAN)
          assert_operator calls.length, :>=, 1, "Part2Label.exists? was not consulted"
        end
      end

      # --- shape ---

      test "part2? answers strictly true or false" do
        assert_same true, Part2Posture.part2?(**RECORD, content: SUSPECTED)
        assert_same false, Part2Posture.part2?(**RECORD, content: CLEAN)
      end
    end
  end
end
