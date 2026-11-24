# frozen_string_literal: true

module Lakeraven
  module EHR
    class LocationsController < ApplicationController
      disclosure_surface :fhir_api
      rate_limit only: %i[index show]

      # US Core's `name` search. `name` is required: RPMS has no list of every
      # location worth a client's walking, and a blank name would list them.
      def index
        return render_missing_name if params[:name].blank?

        render_bundle(LocationGateway.search(params[:name]).filter_map { |row| Location.find_by_ien(row[:ien])&.to_fhir })
      end

      def show
        location = Location.find_by_ien(params[:ien])

        if location.nil?
          render_operation_outcome(status: :not_found, severity: "error", code: "not-found", diagnostics: "Location not found")
          return
        end

        render_fhir(location.to_fhir)
      end

      private

      def render_missing_name
        render_operation_outcome(status: :bad_request, severity: "error", code: "required",
          diagnostics: "Search parameter 'name' is required")
      end
    end
  end
end
