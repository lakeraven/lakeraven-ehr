# frozen_string_literal: true

require "rpms_rpc/api/immunization_refusal"

module Lakeraven
  module EHR
    # Records a patient's refusal of an immunization on the open encounter.
    # Distinct from ImmunizationGateway (read-only).
    # Wraps RpmsRpc::ImmunizationRefusal
    class ImmunizationRefusalGateway
      FAILURE = { success: false, ien: nil, raw: nil }.freeze

      # reason_ien is the REFUSAL REASON (#9999999.102) IEN the gem files;
      # RpmsRpc::ImmunizationRefusal.reasons lists the valid ones.
      def self.record(dfn, vaccine_ien, reason_ien:, narrative: nil, via: default_provider)
        return FAILURE if via.nil?

        via.record(dfn.to_s, vaccine_ien,
          reason_ien: reason_ien, narrative: narrative)
      end

      def self.default_provider
        ::RpmsRpc::ImmunizationRefusal
      end
    end
  end
end
