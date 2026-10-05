# frozen_string_literal: true

module Lakeraven
  module EHR
    # GET /metadata — FHIR's discovery document.
    #
    # Unauthenticated, like the SMART .well-known document beside it: a client
    # has to read the capabilities to know how to authenticate, so requiring a
    # token to learn that is circular. It exposes no patient data.
    class CapabilityStatementsController < ApplicationController
      # Named explicitly and WITHOUT raise: false -- a renamed callback should
      # break the build, not silently re-authenticate discovery. An earlier
      # version of this skipped :authenticate_smart_request!, which does not
      # exist, and raise: false swallowed it.
      skip_before_action :authenticate_smart_token!
      skip_before_action :authorize_fhir_scope!
      skip_before_action :enforce_organization_scope!
      skip_before_action :enforce_patient_compartment_on_search!

      def show
        render json: FHIR::CapabilityStatement.call,
               status: :ok, content_type: FHIR_CONTENT_TYPE
      end
    end
  end
end
