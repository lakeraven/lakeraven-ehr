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

      # The request carries an Authorization header — any scheme, any value,
      # even an empty one. The header SmartAuthentication reads a bearer token
      # from. Decided on presence, before (and never by) authentication.
      def header_authenticated?(request)
        request.headers.key?("Authorization")
      end

      # The chart requests that belong to the fhir_api surface: the FHIR
      # representation, and ANY header-authenticated read, whose HTML is the
      # same clinical content handed to a machine client. Only a browser
      # session with no Authorization header reads the HTML chart ungoverned.
      def fhir_api_request?(request)
        fhir_requested?(request) || header_authenticated?(request)
      end
    end
  end
end
