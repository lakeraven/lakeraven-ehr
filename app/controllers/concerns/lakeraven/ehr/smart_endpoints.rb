# frozen_string_literal: true

module Lakeraven
  module EHR
    # The URLs this engine publishes for SMART clients, built in one place so
    # .well-known/smart-configuration, the EHR launch response and the
    # CapabilityStatement's security extension cannot disagree.
    #
    # The base is the engine's own: the request's scheme and host plus the
    # path the host app mounts the engine at (request.script_name). It used
    # to be request.base_url alone, which drops the mount point, so an engine
    # mounted at /lakeraven-ehr published a token endpoint at /oauth/token
    # that no route serves.
    #
    # A configured token_endpoint_url wins: BackendServicesController accepts
    # only that value as a client assertion's audience, so it is the one
    # endpoint every document must name.
    module SmartEndpoints
      private

      def smart_base_url
        "#{request.base_url}#{request.script_name}/"
      end

      def smart_token_endpoint
        Lakeraven::EHR.configuration.token_endpoint_url.presence || "#{smart_base_url}oauth/token"
      end
    end
  end
end
