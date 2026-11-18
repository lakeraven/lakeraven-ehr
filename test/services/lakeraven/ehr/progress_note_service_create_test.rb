# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # ProgressNoteService#create on a visit (#1001): TIU creates the note
    # under the site's title, then its text is written. Each failure says the
    # step it happened at, and whether a TIU write was sent, so the chart can
    # say what RPMS established: no note, or a note without its text.
    class ProgressNoteServiceCreateTest < ActiveSupport::TestCase
      NOTE_IEN = 7001
      VISIT_IEN = "501"
      TITLE_IEN = 1234
      TEXT = "SYNTHETIC-NOTE-BODY"

      # Answers as ProgressNoteGateway does, and records each call.
      class RecordingNoteGateway
        attr_reader :calls

        def initialize(create: { success: true, ien: NOTE_IEN, raw: NOTE_IEN.to_s },
                       update_text: { success: true, raw: NOTE_IEN.to_s })
          @create = create
          @update_text = update_text
          @calls = []
        end

        def create(dfn, visit_ien, title_ien)
          @calls << [ :create, dfn.to_s, visit_ien.to_s, title_ien.to_s ]
          @create
        end

        def update_text(note_ien, text)
          @calls << [ :update_text, note_ien.to_s, text ]
          @update_text
        end
      end

      def service(gateway, visit_ien: VISIT_IEN)
        ProgressNoteService.new(dfn: "3", visit_ien: visit_ien, author_duz: "99999",
                                gateway: gateway, esignature_gateway: Object.new)
      end

      test "create files the note on the visit under the title, then writes its text" do
        gateway = RecordingNoteGateway.new
        notes = service(gateway)

        result = notes.create(title_ien: TITLE_IEN, text: TEXT)

        assert result.success?, "error: #{result.error.inspect}"
        assert_equal NOTE_IEN, result.note_ien
        assert_equal NOTE_IEN, notes.created_note_ien
        assert notes.write_sent?
        assert_equal [ [ :create, "3", VISIT_IEN, TITLE_IEN.to_s ], [ :update_text, NOTE_IEN.to_s, TEXT ] ],
                     gateway.calls
      end

      test "create says the note was not created when TIU refuses it, and writes no text" do
        gateway = RecordingNoteGateway.new(create: { success: false, ien: nil, raw: "0^refused" })
        notes = service(gateway)

        result = notes.create(title_ien: TITLE_IEN, text: TEXT)

        refute result.success?
        assert_equal :gateway_error, result.error
        assert_equal :create, result.stage
        assert_nil result.note_ien
        assert_nil notes.created_note_ien
        assert notes.write_sent?, "the create was sent"
        assert_equal %i[create], gateway.calls.map(&:first)
      end

      test "create names the note that exists without its text when the text write is refused" do
        gateway = RecordingNoteGateway.new(update_text: { success: false, raw: "0^refused" })
        notes = service(gateway)

        result = notes.create(title_ien: TITLE_IEN, text: TEXT)

        refute result.success?
        assert_equal :gateway_error, result.error
        assert_equal :text, result.stage
        assert_equal NOTE_IEN, result.note_ien
        assert_equal NOTE_IEN, notes.created_note_ien
      end

      test "create sends nothing to TIU without a visit or a title" do
        gateway = RecordingNoteGateway.new

        [ service(gateway, visit_ien: nil).then { |s| [ s, s.create(title_ien: TITLE_IEN, text: TEXT) ] },
          service(gateway).then { |s| [ s, s.create(title_ien: nil, text: TEXT) ] } ].each do |notes, result|
          refute result.success?
          assert_equal :create, result.stage
          refute notes.write_sent?
        end
        assert_empty gateway.calls
      end
    end
  end
end
