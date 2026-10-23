# frozen_string_literal: true

require "rpms_rpc/api/image"

module Lakeraven
  module EHR
    # Imaging-study list. Wraps RpmsRpc::Image. There is no viewer-launch
    # token: rpms-rpc #311 removed Image.launch_token with MAGG IMAGE LAUNCH
    # TOKEN, which no built image registers.
    class ImageGateway
      def self.exams_for_patient(dfn, via: default_provider)
        return [] if via.nil?

        via.exams_for_patient(dfn.to_s)
      end

      def self.default_provider
        ::RpmsRpc::Image
      end
    end
  end
end
