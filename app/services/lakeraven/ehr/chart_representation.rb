# frozen_string_literal: true

module Lakeraven
  module EHR
    # The chart's content negotiation (#452), in one place: ChartsController
    # renders the FHIR Bundle exactly when this says so, and the fhir_api
    # disclosure surface (#522) refuses exactly those requests.
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
    end
  end
end
