# frozen_string_literal: true

module Lakeraven
  module EHR
    # The rpms-rpc client objects themselves, for the callers that need a
    # client rather than an RPC: the FHIR client, and whether the backend's
    # client is the in-process mock. They live here so that no code outside
    # the door resolves a client (ADR 0013, decision 6e).
    module RpmsClientGateway
      module_function

      # Raises RpmsRpc::NotConfiguredError when no FHIR client is configured.
      def fhir_client
        ::RpmsRpc.fhir_client
      end

      # Whether the current backend's client is the in-process mock.
      def mock_backend?
        defined?(::RpmsRpc::MockClient) && BackendRegistry.current.client.is_a?(::RpmsRpc::MockClient)
      end
    end
  end
end
