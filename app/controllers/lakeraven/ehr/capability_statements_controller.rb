# frozen_string_literal: true

module Lakeraven
  module EHR
    # GET /metadata: the FHIR CapabilityStatement (#574).
    #
    # Unauthenticated, like .well-known/smart-configuration beside it: a
    # client reads the capabilities to learn how to authenticate, so asking
    # for a token first is circular. It carries no patient data. It is an
    # ActionController::API for the same reason SmartConfigurationController
    # is, rather than an ApplicationController that skips the token filters:
    # a skip list breaks quietly when a filter is renamed or added.
    class CapabilityStatementsController < ActionController::API
      include SmartEndpoints

      def show
        statement = FHIR::CapabilityStatement.call(
          base_url: smart_base_url.chomp("/"), token_endpoint: smart_token_endpoint
        )
        render json: statement, status: :ok, content_type: ApplicationController::FHIR_CONTENT_TYPE
      end
    end
  end
end
