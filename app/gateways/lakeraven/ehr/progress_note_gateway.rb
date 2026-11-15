# frozen_string_literal: true

require "rpms_rpc/api/progress_note"

module Lakeraven
  module EHR
    # TIU progress note create, list, fetch, edit, lock. Signing lives in
    # ESignatureGateway, not here.
    # Wraps RpmsRpc::ProgressNote
    class ProgressNoteGateway
      CREATE_FAILURE = { success: false, ien: nil, raw: nil }.freeze
      UPDATE_FAILURE = { success: false, raw: nil }.freeze

      def self.create(dfn, visit_ien, title_ien, via: default_provider)
        return CREATE_FAILURE if via.nil?

        via.create(dfn.to_s, visit_ien.to_s, title_ien.to_s)
      end

      def self.list(dfn, context: :all, via: default_provider)
        return [] if via.nil?

        via.list(dfn.to_s, context: context)
      end

      def self.fetch_text(note_ien, via: default_provider)
        return nil if via.nil?

        via.fetch_text(note_ien.to_s)
      end

      # The body rows of the note, or nil. TIU GET RECORD TEXT returns a
      # display: header rows, ONE blank row, then the body. The separator is
      # the first row that is empty after strip. The header changes on
      # signing (STATUS: UNSIGNED becomes COMPLETED) and TIU appends a
      # signature block after the body, so only the body rows are evidence
      # of the note. Text with no blank row is an unrecognised shape, not
      # evidence, so it gives nil.
      def self.fetch_body(note_ien, via: default_provider)
        text = fetch_text(note_ien, via: via)
        return nil unless text.is_a?(String)

        rows = text.split(/\r\n|\r|\n/, -1)
        header_end = rows.index { |row| row.strip.empty? }
        return nil if header_end.nil?

        body = rows.drop(header_end + 1)
        body.pop while body.last == ""
        body
      end

      # TIU AUTHORIZATION, TIU LOCK RECORD and TIU UNLOCK RECORD act as the
      # signed-on user (CANDO^TIUSRVA, LOCK^TIUSRVP), so none takes a user.
      def self.authorize(note_ien, action: ::RpmsRpc::ProgressNote::EDIT_RECORD, via: default_provider)
        return false if via.nil?

        via.authorize(note_ien.to_s, action: action)
      end

      def self.lock(note_ien, via: default_provider)
        return false if via.nil?

        via.lock(note_ien.to_s)
      end

      def self.update_text(note_ien, text, via: default_provider)
        return UPDATE_FAILURE if via.nil?

        via.update_text(note_ien.to_s, text)
      end

      def self.unlock(note_ien, via: default_provider)
        return false if via.nil?

        via.unlock(note_ien.to_s)
      end

      def self.default_provider
        ::RpmsRpc::ProgressNote
      end
    end
  end
end
