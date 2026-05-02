# frozen_string_literal: true

require "rpms_rpc/api/vfc"

module Lakeraven
  module EHR
    class EligibilityGateway
      def self.patient_eligibility(dfn)
        RpmsRpc::VFC.eligibility(dfn)
      end

      def self.list_codes
        RpmsRpc::VFC.eligibility_codes
      end
    end
  end
end
