# frozen_string_literal: true

module Lakeraven
  module EHR
    # SMART App Launch Framework - Well-Known Configuration
    # ONC 170.315(g)(10) — SMART on FHIR discovery endpoint
    #
    # The document is SmartDiscovery's, which also builds the
    # CapabilityStatement's security element: only served endpoints, and only
    # scopes the token endpoint grants (#657, #658).
    class SmartConfigurationController < ActionController::API
      include SmartEndpoints

      def show
        render json: SmartDiscovery.new(token_endpoint: smart_token_endpoint).configuration, status: :ok
      end
    end
  end
end
