# frozen_string_literal: true

require "rpms_rpc/api/allergy"

module Lakeraven
  module EHR
    class AllergyIntoleranceGateway
      def self.for_patient(dfn)
        RpmsRpc::Allergy.for_patient(dfn.to_s)
      end
    end
  end
end
