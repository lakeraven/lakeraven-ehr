# frozen_string_literal: true

module Lakeraven
  module EHR
    class ConditionGateway
      def self.for_patient(dfn)
        if RpmsRpc.configuration.fhir_client.present?
          FHIRReadGateway.search("Condition", patient: dfn.to_s)
        else
          require "rpms_rpc/mappings"
          RpmsRpc::DataMapper.problem_list.fetch_many(dfn.to_s).map { |attrs| Condition.new(**attrs) }
        end
      end
    end
  end
end
