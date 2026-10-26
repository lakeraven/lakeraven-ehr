# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationRequestsController < ApplicationController
      include PatientCompartment

      rate_limit only: %i[index show]

      compartment_bound :index, param: :patient, require_param: true

      def index
        dfn = patient_compartment_dfn
        statuses = status_search
        return if performed?

        resources = MedicationRequest.for_patient(dfn).map { |r| MedicationRequest.from_rpms_row(r, patient_dfn: dfn) }
        resources = resources.select { |r| statuses.include?(r.status) } if statuses
        render_bundle_egress(resources.map(&:to_fhir))
      end

      def show
        render_not_found("MedicationRequest", params[:id])
      end

      private

      # `status` is a token: comma-separated codes, any of which matches.
      # A system|code value is refused rather than matched as a code.
      def status_search
        return nil unless params.key?(:status)

        raw = params[:status]
        unless raw.is_a?(String) && raw.strip.present? && !raw.include?("|")
          return refuse_search_parameter("status", "comma-separated MedicationRequest status codes")
        end

        raw.split(",").map(&:strip)
      end
    end
  end
end
