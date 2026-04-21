# frozen_string_literal: true

module Lakeraven
  module EHR
    class LocationsController < ApplicationController
      def show
        location = Location.find_by_ien(params[:ien])

        if location.nil?
          render_operation_outcome(status: :not_found, severity: "error", code: "not-found", diagnostics: "Location not found")
          return
        end

        render_fhir(location.to_fhir)
      end
    end
  end
end
