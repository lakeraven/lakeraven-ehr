# frozen_string_literal: true

begin
  require "rpms_rpc/api/note_template"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::NoteTemplate.
end

module Lakeraven
  module EHR
    # TIU note template tree, boilerplate text, and per-user access level.
    # Wraps RpmsRpc::NoteTemplate (lakeraven/rpms-rpc#56).
    class NoteTemplateGateway
      def self.roots(user_duz, via: default_provider)
        return [] if via.nil?

        via.roots(user_duz.to_s)
      end

      def self.items(template_ien, via: default_provider)
        return [] if via.nil?

        via.items(template_ien.to_s)
      end

      def self.boilerplate(template_ien, dfn:, visit_ien:, via: default_provider)
        return nil if via.nil?

        via.boilerplate(template_ien.to_s, dfn: dfn.to_s, visit_ien: visit_ien.to_s)
      end

      def self.text(template_ien, via: default_provider)
        return nil if via.nil?

        via.text(template_ien.to_s)
      end

      def self.access_level(template_ien, user_duz, via: default_provider)
        return nil if via.nil?

        via.access_level(template_ien.to_s, user_duz.to_s)
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::NoteTemplate) &&
                          ::RpmsRpc::NoteTemplate.respond_to?(:roots)
        ::RpmsRpc::NoteTemplate
      end
    end
  end
end
