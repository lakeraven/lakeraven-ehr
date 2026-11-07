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

      def smart_authorization_endpoint
        "#{smart_fhir_base_url}/oauth/authorize"
      end

      # The FHIR base URL, the one value a launch's `aud` must name. Read off
      # the configured token endpoint when there is one, so a proxy that
      # rewrites Host cannot change it; otherwise the engine's own base.
      def smart_fhir_base_url
        configured = Lakeraven::EHR.configuration.token_endpoint_url.presence
        return configured.delete_suffix("/oauth/token") if configured&.end_with?("/oauth/token")

        smart_base_url.chomp("/")
      end
    end
  end
end
