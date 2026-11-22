# frozen_string_literal: true

module Lakeraven
  module EHR
    # Which chart requests are the FHIR API surface (#969). ChartsController
    # renders and gates from these, so the two can never disagree.
    module ChartRepresentation
      module_function

      FHIR_CONTENT_TYPE = "application/fhir+json"

      # The FHIR Bundle was asked for: .json, ?_format=json, or an Accept
      # header naming application/fhir+json. Reads path + query params as the
      # controller's params does.
      def fhir_requested?(request)
        params = request.parameters
        return true if params[:format].to_s == "json"
        return true if params[:_format].to_s == "json"

        request.headers["Accept"].to_s.include?(FHIR_CONTENT_TYPE)
      end

      # The FHIR form, or any read presenting a Bearer Authorization header.
      def fhir_api_request?(request)
        fhir_requested?(request) || SmartAuthentication.bearer_authorization?(request)
      end
    end
  end
end
