# frozen_string_literal: true

module Lakeraven
  module EHR
    class ProcedureGateway
      def self.for_patient(dfn)
        if RpmsRpc.configuration.fhir_client.present?
          FHIRReadGateway.search("Procedure", patient: dfn.to_s)
        else
          require "rpms_rpc/mappings"
          RpmsRpc::DataMapper.procedure_list.fetch_many(dfn.to_s).map { |attrs| Procedure.new(**attrs) }
        end
      end
    end
  end
end
