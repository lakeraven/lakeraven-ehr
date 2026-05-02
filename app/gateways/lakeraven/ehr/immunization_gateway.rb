# frozen_string_literal: true

require "rpms_rpc/api/allergy"

module Lakeraven
  module EHR
    class ImmunizationGateway
      # TODO: migrate to RpmsRpc::Immunization.for_patient when
      # immunization-specific RPC (BIPC IMMLIST) is wired.
      # Currently delegates to allergy_list for backward compatibility.
      def self.for_patient(dfn)
        RpmsRpc::Allergy.for_patient(dfn.to_s)
      end
    end
  end
end
