# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # A Part 2 label that cannot be written because the connection pool is
    # exhausted (#906 continue). Part2Label.mark! runs detached: a second
    # pooled connection taken inside the caller's open transaction. With the
    # pool exhausted that checkout times out
    # (ActiveRecord::ConnectionTimeoutError, an ActiveRecordError), the note
    # is still filed, and the service reports :label_failed.
    #
    # The outcome also has to be readable from the service INSTANCE, so a
    # caller (ProgressNotesController, writing the submission's audit row)
    # can record it even when a later step raises and no Result comes back.
    # Synthetic identifiers throughout.
    class ProgressNoteServicePart2LabelTimeoutTest < ActiveSupport::TestCase
      DFN = "1001"
      VISIT_IEN = "2090061"
      AUTHOR_DUZ = "301"
      TITLE_IEN = 4321
      NOTE_IEN = 70001
      SUD_TEXT = "Counselled on alcohol use disorder."
      CLEAN_TEXT = "Seen for follow-up. Vitals stable."
      SYNTHETIC_TIMEOUT_MESSAGE = "SYNTHETIC-POOL-MESSAGE"

      class FakeNoteGateway
        def create(_dfn, _visit_ien, _title_ien) = { success: true, ien: NOTE_IEN, raw: NOTE_IEN.to_s }
        def update_text(_note_ien, _text) = { success: true, raw: "0" }
      end

      # A gateway whose text write raises, so create never returns a Result.
      class RaisingTextGateway < FakeNoteGateway
        def update_text(_note_ien, _text) = raise(::RpmsRpc::Error, "SYNTHETIC-BROKER-TEXT-906")
      end

      setup { Part2Label.delete_all }
      teardown { Part2Label.delete_all }

      def service(gateway: FakeNoteGateway.new)
        ProgressNoteService.new(dfn: DFN, visit_ien: VISIT_IEN, author_duz: AUTHOR_DUZ, gateway: gateway)
      end

      def note_labels
        Part2Label.where(record_type: "tiu_note", record_id: NOTE_IEN.to_s)
      end

      # mark! fails the way a pool checkout timeout fails.
      def with_pool_timeout_on_mark
        restore = singleton_method_restore(Part2Label, :mark!)
        Part2Label.define_singleton_method(:mark!) do |*_args, **_kwargs|
          raise ActiveRecord::ConnectionTimeoutError, SYNTHETIC_TIMEOUT_MESSAGE
        end
        yield
      ensure
        restore&.call
      end

      test "a label whose connection checkout times out does not block the note" do
        result = nil
        with_pool_timeout_on_mark { result = service.create(title_ien: TITLE_IEN, text: SUD_TEXT) }

        assert result.success?, "the note is not blocked by the label write: #{result&.error.inspect}"
        assert_equal NOTE_IEN, result.note_ien
        assert_equal :label_failed, result.part2_label
        assert_equal 0, note_labels.count
      end

      test "the service instance reports a label that timed out as label_failed" do
        note_service = service

        with_pool_timeout_on_mark { note_service.create(title_ien: TITLE_IEN, text: SUD_TEXT) }

        assert_equal :label_failed, note_service.part2_label
      end

      test "the service instance reports nothing about the label before create" do
        assert_nil service.part2_label
      end

      test "the service instance reports a written label as labelled" do
        note_service = service

        result = note_service.create(title_ien: TITLE_IEN, text: SUD_TEXT)

        assert result.success?, "error: #{result.error.inspect}"
        assert_equal :labelled, note_service.part2_label
        assert_equal 1, note_labels.count
      end

      test "the service instance reports clean text as not_suspected" do
        note_service = service

        result = note_service.create(title_ien: TITLE_IEN, text: CLEAN_TEXT)

        assert result.success?, "error: #{result.error.inspect}"
        assert_equal :not_suspected, note_service.part2_label
        assert_equal 0, Part2Label.count
      end

      test "the service instance still reports a failed label when a later step raises" do
        note_service = service(gateway: RaisingTextGateway.new)

        with_pool_timeout_on_mark do
          assert_raises(::RpmsRpc::Error) do
            note_service.create(title_ien: TITLE_IEN, text: SUD_TEXT)
          end
        end

        assert_equal NOTE_IEN, note_service.created_note_ien
        assert_equal :label_failed, note_service.part2_label
      end
    end

    # The same, with a REAL exhausted pool: outside the transactional-test
    # harness (so the connection is not pinned and mark! really detaches),
    # inside an open transaction, with every other connection of the pool
    # held and a short checkout timeout.
    class ProgressNoteServiceRealPoolExhaustionTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      DFN = "1002"
      VISIT_IEN = "2090062"
      AUTHOR_DUZ = "302"
      TITLE_IEN = 4321
      NOTE_IEN = 70002
      SUD_TEXT = "Counselled on alcohol use disorder."
      CHECKOUT_TIMEOUT = 0.25

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

      # Holds every connection of the pool but this thread's own, with a
      # short checkout timeout, so another thread's checkout times out
      # quickly. Everything is handed back in ensure.
      def with_exhausted_pool
        pool = Part2Label.connection_pool
        timeout_was = pool.checkout_timeout
        pool.checkout_timeout = CHECKOUT_TIMEOUT
        held = []
        begin
          loop { held << pool.checkout }
        rescue ActiveRecord::ConnectionTimeoutError
          nil
        end
        yield
      ensure
        held&.each { |connection| pool.checkin(connection) }
        pool.checkout_timeout = timeout_was
      end

      test "a note whose label cannot take a pooled connection is filed and reported as label_failed" do
        result = nil
        note_service = service

        ActiveRecord::Base.transaction do
          with_exhausted_pool { result = note_service.create(title_ien: TITLE_IEN, text: SUD_TEXT) }
        end

        assert result.success?, "the note is not blocked by the label write: #{result&.error.inspect}"
        assert_equal NOTE_IEN, result.note_ien
        assert_equal :label_failed, result.part2_label
        assert_equal :label_failed, note_service.part2_label
        assert_equal 0, note_labels.count
      end
    end
  end
end
