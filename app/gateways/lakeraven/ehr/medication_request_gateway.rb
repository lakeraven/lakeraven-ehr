# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationRequestGateway
      def self.for_patient(dfn)
        if RpmsRpc.configuration.fhir_client.present?
          FHIRReadGateway.search("MedicationRequest", patient: dfn.to_s)
        else
          require "rpms_rpc/mappings"
          RpmsRpc::DataMapper.medication_list.fetch_many(dfn.to_s).map { |attrs| MedicationRequest.new(**attrs) }
        end
      end
    end
  end
end
