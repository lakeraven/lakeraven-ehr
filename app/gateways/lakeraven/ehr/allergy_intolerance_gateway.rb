# frozen_string_literal: true

module Lakeraven
  module EHR
    class AllergyIntoleranceGateway
      def self.for_patient(dfn)
        if RpmsRpc.configuration.fhir_client.present?
          FHIRReadGateway.search("AllergyIntolerance", patient: dfn.to_s)
        else
          require "rpms_rpc/mappings"
          RpmsRpc::DataMapper.allergy_list.fetch_many(dfn.to_s).map { |attrs| AllergyIntolerance.new(**attrs) }
        end
      end
    end
  end
end
