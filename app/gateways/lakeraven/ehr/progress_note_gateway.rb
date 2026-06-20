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

      def self.authorize(note_ien, user_duz, via: default_provider)
        return false if via.nil?

        via.authorize(note_ien.to_s, user_duz.to_s)
      end

      def self.lock(note_ien, user_duz, via: default_provider)
        return false if via.nil?

        via.lock(note_ien.to_s, user_duz.to_s)
      end

      def self.update_text(note_ien, text, via: default_provider)
        return UPDATE_FAILURE if via.nil?

        via.update_text(note_ien.to_s, text)
      end

      def self.unlock(note_ien, user_duz, via: default_provider)
        return false if via.nil?

        via.unlock(note_ien.to_s, user_duz.to_s)
      end

      def self.default_provider
        ::RpmsRpc::ProgressNote
      end
    end
  end
end
