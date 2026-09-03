# frozen_string_literal: true

require "rpms_rpc/api/care_plan"

module Lakeraven
  module EHR
    class CarePlanGateway
      def self.for_patient(dfn)
        RpmsRpc::CarePlan.for_patient(dfn.to_s)
      end
    end
  end
end
