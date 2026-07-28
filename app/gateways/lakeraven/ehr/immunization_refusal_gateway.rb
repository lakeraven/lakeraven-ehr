# frozen_string_literal: true

require "rpms_rpc/api/immunization_refusal"

module Lakeraven
  module EHR
    # Records a patient's refusal of an immunization on the open encounter.
    # Distinct from ImmunizationGateway (read-only).
    # Wraps RpmsRpc::ImmunizationRefusal
    class ImmunizationRefusalGateway
      FAILURE = { success: false, ien: nil, raw: nil }.freeze

      def self.record(dfn, vaccine_code, reason_code:, narrative: nil, via: default_provider)
        return FAILURE if via.nil?

        via.record(dfn.to_s, vaccine_code,
          reason_code: reason_code, narrative: narrative)
      end

      def self.default_provider
        ::RpmsRpc::ImmunizationRefusal
      end
    end
  end
end
