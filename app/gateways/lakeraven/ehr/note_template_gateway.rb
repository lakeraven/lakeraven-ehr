# frozen_string_literal: true

require "rpms_rpc/api/note_template"

module Lakeraven
  module EHR
    # TIU note template tree, boilerplate text, and per-user access level.
    # Wraps RpmsRpc::NoteTemplate
    class NoteTemplateGateway
      def self.roots(user_duz, via: default_provider)
        return [] if via.nil?

        via.roots(user_duz.to_s)
      end

      def self.items(template_ien, via: default_provider)
        return [] if via.nil?

        via.items(template_ien.to_s)
      end

      # The template's UNEXPANDED boilerplate. GETBOIL^TIUSRVT takes the
      # template alone; expanding |FIELD| objects is text's job.
      def self.boilerplate(template_ien, via: default_provider)
        return nil if via.nil?

        via.boilerplate(template_ien.to_s)
      end

      # Boilerplate lines expanded for a patient (and visit): the server
      # resolves |FIELD| objects. GETTEXT^TIUSRVT takes the lines, not a
      # template IEN.
      def self.text(lines, dfn:, visit_string: "", via: default_provider)
        return nil if via.nil?

        via.text(Array(lines), dfn: dfn.to_s, visit_string: visit_string.to_s)
      end

      def self.access_level(template_ien, user_duz, via: default_provider)
        return nil if via.nil?

        via.access_level(template_ien.to_s, user_duz.to_s)
      end

      def self.default_provider
        ::RpmsRpc::NoteTemplate
      end
    end
  end
end
