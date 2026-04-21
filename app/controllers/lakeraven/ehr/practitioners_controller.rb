# frozen_string_literal: true

module Lakeraven
  module EHR
    class PractitionersController < ApplicationController
      def index
        practitioners = if params[:name].present?
          Practitioner.search(params[:name])
        else
          Practitioner.search("")
        end

        render_bundle(practitioners.map(&:to_fhir))
      end

      def show
        practitioner = Practitioner.find_by_ien(params[:ien])

        if practitioner.nil?
          render_operation_outcome(
            status: :not_found,
            severity: "error",
            code: "not-found",
            diagnostics: "Practitioner not found"
          )
          return
        end

        render_fhir(practitioner.to_fhir)
      end
    end
  end
end
