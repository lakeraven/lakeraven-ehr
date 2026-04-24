# frozen_string_literal: true

module Lakeraven
  module EHR
    class ObservationGateway
      def self.for_patient(dfn)
        if RpmsRpc.configuration.fhir_client.present?
          FHIRReadGateway.search("Observation", patient: dfn.to_s)
        else
          require "rpms_rpc/mappings"
          RpmsRpc::DataMapper.vitals.fetch_many(dfn.to_s).map { |attrs| Observation.new(**attrs) }
        end
      end
    end
  end
end
