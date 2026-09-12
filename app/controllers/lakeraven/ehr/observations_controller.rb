# frozen_string_literal: true

module Lakeraven
  module EHR
    class ObservationsController < ApplicationController
      include PatientCompartment

      def index
        dfn = patient_compartment_dfn
        raw = Observation.for_patient(dfn)
        observations = Observation.from_vital_hashes(raw, patient_dfn: dfn)
        observations = filter_observations(observations)
        render_bundle(observations.map(&:to_fhir))
      end

      def show
        render_not_found("Observation", params[:id])
      end

      private

      def filter_observations(observations)
        observations = observations.select { |o| o.category == params[:category] } if params[:category].present?
        if params[:code].present?
          codes = params[:code].split(",")
          observations = observations.select { |o| codes.include?(o.code) }
        end
        observations
      end
    end
  end
end
