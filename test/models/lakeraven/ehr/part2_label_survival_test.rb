# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # A Part 2 label written inside a transaction that then rolls back stays
    # written (#906): the request's audit transaction (AuditableClinicalAccess)
    # can roll back after a note was filed in RPMS, and the note must keep
    # its label. And a label statement that fails at the database must not
    # abort the caller's transaction. Outside the transactional-test harness,
    # the way production runs. Synthetic identifiers throughout.
    class Part2LabelSurvivalTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      DFN = "1001"
      VISIT_IEN = "2090061"
      AUTHOR_DUZ = "301"
      TITLE_IEN = 4321
      NOTE_IEN = 70001
      SUD_TEXT = "Counselled on alcohol use disorder."
      MISSING_TABLE = "lakeraven_ehr_part2_labels_synthetic_missing"

      class FakeNoteGateway
        def create(_dfn, _visit_ien, _title_ien) = { success: true, ien: NOTE_IEN, raw: NOTE_IEN.to_s }
        def update_text(_note_ien, _text) = { success: true, raw: "0" }
      end

      setup { Part2Label.delete_all }
      teardown { Part2Label.delete_all }

      def service
        ProgressNoteService.new(dfn: DFN, visit_ien: VISIT_IEN, author_duz: AUTHOR_DUZ, gateway: FakeNoteGateway.new)
      end

      def note_labels
        Part2Label.where(record_type: "tiu_note", record_id: NOTE_IEN.to_s)
      end

      # Points Part2Label at a table that does not exist, so its statements
      # fail for real at PostgreSQL, and puts the real table back after.
      def with_missing_label_table
        original = Part2Label.table_name
        Part2Label.table_name = MISSING_TABLE
        Part2Label.reset_column_information
        yield
      ensure
        Part2Label.table_name = original
        Part2Label.reset_column_information
      end

      test "a label marked in a transaction that rolls back is still there" do
        marked = nil
        ActiveRecord::Base.transaction do
          marked = Part2Label.mark!(patient_dfn: DFN, record_type: "tiu_note", record_id: NOTE_IEN.to_s)
          raise ActiveRecord::Rollback
        end

        assert_kind_of Part2Label, marked
        assert_equal 1, note_labels.count, "the label was rolled back with the caller's transaction"
        assert_equal "42CFRPart2", note_labels.first.security_code
        assert_equal DFN, note_labels.first.patient_dfn
      end

      test "a label the service reported as labelled survives the caller's rollback" do
        result = nil
        ActiveRecord::Base.transaction do
          result = service.create(title_ien: TITLE_IEN, text: SUD_TEXT)
          raise ActiveRecord::Rollback
        end

        assert result.success?, "error: #{result.error.inspect}"
        assert_equal :labelled, result.part2_label
        assert_equal 1, note_labels.count, "reported :labelled, but the label was rolled back with the caller's transaction"
      end

      test "a label statement that fails at the database leaves the caller's transaction usable" do
        result = nil
        following = nil
        raised = nil

        with_missing_label_table do
          ActiveRecord::Base.transaction do
            result = service.create(title_ien: TITLE_IEN, text: SUD_TEXT)
            begin
              following = ActiveRecord::Base.connection.select_value("SELECT 1")
            rescue ActiveRecord::StatementInvalid => e
              raised = e
            end
            raise ActiveRecord::Rollback
          end
        end

        assert result.success?, "the note is not blocked by the label write: #{result.error.inspect}"
        assert_equal :label_failed, result.part2_label
        assert_nil raised, "the failed label statement aborted the caller's transaction: #{raised.class}"
        assert_equal 1, following.to_i
      end

      test "marking an already labelled record inside a transaction leaves it usable" do
        Part2Label.mark!(patient_dfn: DFN, record_type: "tiu_note", record_id: NOTE_IEN.to_s)

        ActiveRecord::Base.transaction do
          again = Part2Label.mark!(patient_dfn: DFN, record_type: "tiu_note", record_id: NOTE_IEN.to_s)
          assert_kind_of Part2Label, again
          assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT 1").to_i
        end
        assert_equal 1, note_labels.count
      end
    end
  end
end
