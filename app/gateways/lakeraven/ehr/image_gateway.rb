# frozen_string_literal: true

begin
  require "rpms_rpc/api/image"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::Image.
end

module Lakeraven
  module EHR
    # Imaging-study list and viewer-launch handoff. The viewer is a
    # desktop component external to RPMS; the gateway issues a token
    # the front-end hands off to whatever viewer is configured.
    # Wraps RpmsRpc::Image (lakeraven/rpms-rpc#75).
    class ImageGateway
      DEFAULT_TTL_SECONDS = 300

      def self.exams_for_patient(dfn, via: default_provider)
        return [] if via.nil?

        via.exams_for_patient(dfn.to_s)
      end

      def self.launch_token(dfn, study_ien, ttl_seconds: DEFAULT_TTL_SECONDS, via: default_provider)
        return nil if via.nil?

        via.launch_token(dfn.to_s, study_ien.to_s, ttl_seconds: ttl_seconds)
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::Image) &&
                          ::RpmsRpc::Image.respond_to?(:launch_token)
        ::RpmsRpc::Image
      end
    end
  end
end
