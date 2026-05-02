# frozen_string_literal: true

require "rpms_rpc/api/problem"

module Lakeraven
  module EHR
    class ConditionGateway
      def self.for_patient(dfn)
        RpmsRpc::Problem.for_patient(dfn.to_s)
      end
    end
  end
end
