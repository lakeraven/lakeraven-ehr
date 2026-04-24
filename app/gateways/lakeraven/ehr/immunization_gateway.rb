# frozen_string_literal: true

module Lakeraven
  module EHR
    class ImmunizationGateway
      def self.for_patient(dfn)
        if RpmsRpc.configuration.fhir_client.present?
          FHIRReadGateway.search("Immunization", patient: dfn.to_s)
        else
          require "rpms_rpc/mappings"
          RpmsRpc::DataMapper.immunization_list.fetch_many(dfn.to_s).map { |attrs| Immunization.new(**attrs) }
        end
      end
    end
  end
end
