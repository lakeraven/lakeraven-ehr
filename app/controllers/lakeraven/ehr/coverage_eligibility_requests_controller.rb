# frozen_string_literal: true

module Lakeraven
  module EHR
    class CoverageEligibilityRequestsController < ApplicationController
      def create
        request = CoverageEligibilityRequest.new(eligibility_params)

        unless request.valid?
          render_operation_outcome(
            status: :unprocessable_content,
            severity: "error",
            code: "invalid",
            diagnostics: request.errors.full_messages.join(", ")
          )
          return
        end

        result = EligibilityCheck.call(request)
        render_fhir(result.to_fhir)
      end

      private

      def eligibility_params
        params.permit(:patient_dfn, :coverage_type, :provider_npi, :service_date, :purpose)
      end
    end
  end
end
