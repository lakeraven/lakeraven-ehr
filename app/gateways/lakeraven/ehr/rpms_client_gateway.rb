# frozen_string_literal: true

module Lakeraven
  module EHR
    # The callers that need the rpms-rpc client objects rather than an RPC:
    # the FHIR client's reads, and whether the backend's client is the
    # in-process mock. The calls are made here, so no client leaves the door
    # (ADR 0013, decision 6e).
    module RpmsClientGateway
      module_function

      # Whether a FHIR client is configured. Any error counts as not.
      def fhir_available?
        ::RpmsRpc.respond_to?(:fhir_client) && ::RpmsRpc.fhir_client.present?
      rescue
        false
      end

      # The Patient resource for the DFN as the FHIR client reads it (a hash,
      # possibly an OperationOutcome), or nil. Errors propagate to the caller.
      def read_fhir_patient(dfn)
        ::RpmsRpc.fhir_client.read("Patient", dfn.to_s)
      end

      # Whether the current backend's client is the in-process mock.
      def mock_backend?
        defined?(::RpmsRpc::MockClient) && BackendRegistry.current.client.is_a?(::RpmsRpc::MockClient)
      end
    end
  end
end
