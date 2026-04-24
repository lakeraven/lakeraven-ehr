# frozen_string_literal: true

module Lakeraven
  module EHR
    # Single FHIR read gateway for all resource types.
    # Routes reads to RpmsRpc.fhir_client (IRIS for Health or mock).
    # Each model provides from_fhir(hash) for deserialization.
    class FHIRReadGateway
      class << self
        def read(resource_type, id)
          result = RpmsRpc.fhir_client.read(resource_type, id.to_s)
          return nil if result["resourceType"] == "OperationOutcome"

          model_class(resource_type).from_fhir(result)
        end

        def search(resource_type, params = {})
          bundle = RpmsRpc.fhir_client.search(resource_type, params)
          entries = bundle["entry"] || []
          entries.map { |e| model_class(resource_type).from_fhir(e["resource"]) }
        end

        private

        def model_class(resource_type)
          Lakeraven::EHR.const_get(resource_type)
        end
      end
    end
  end
end
