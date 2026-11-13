# frozen_string_literal: true

module Lakeraven
  module EHR
    # The chart's content negotiation (#452) and its fhir_api disclosure rule
    # (#522), in one place: ChartsController renders the FHIR Bundle exactly
    # when fhir_requested? says so, and both the chart route constraint and
    # the chart controller's disclosure gate refuse exactly the requests
    # fhir_api_request? names while fhir_api is closed.
    module ChartRepresentation
      FHIR_CONTENT_TYPE = "application/fhir+json"

      module_function

      # `.json`, `?_format=json`, or an Accept naming application/fhir+json.
      def fhir_requested?(request)
        # The same conversion ActionController::Parameters makes, so `params`
        # here reads exactly what the controller's `params` reads.
        params = ActiveSupport::HashWithIndifferentAccess.new(request.parameters)
        return true if params[:format].to_s == "json"
        return true if params[:_format].to_s == "json"

        request.headers["Accept"].to_s.include?(FHIR_CONTENT_TYPE)
      end

      # The chart requests that belong to the fhir_api surface: the FHIR
      # representation, and any read carrying a header bearer token, whose HTML
      # is the same clinical content handed to a machine client. "Bearer" is
      # SmartAuthentication's own definition (BEARER_AUTHORIZATION), decided on
      # the header's shape before authentication. Any other Authorization
      # header (a proxy's `Basic`) is not a bearer and falls through to the
      # browser session, exactly as authentication does.
      def fhir_api_request?(request)
        fhir_requested?(request) || SmartAuthentication.bearer_authorization?(request)
      end
    end
  end
end
