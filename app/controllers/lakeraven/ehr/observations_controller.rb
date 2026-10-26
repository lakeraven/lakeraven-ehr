# frozen_string_literal: true

module Lakeraven
  module EHR
    class ObservationsController < ApplicationController
      include PatientCompartment

      rate_limit only: %i[index show]

      compartment_bound :index, param: :patient, require_param: true
      before_action :refuse_system_qualified_tokens!, only: :index

      def index
        dfn = patient_compartment_dfn
        observations = SupplementalClinicalResources.merged_observations_for_patient(dfn)
        observations = filter_observations(observations)
        render_bundle_egress(observations.map(&:to_fhir))
      end

      def show
        render_not_found("Observation", params[:id])
      end

      private

      # category and code compare the code alone. A system|code value used to
      # be compared whole against the code, so it matched nothing and read as
      # "no observations"; it is refused instead, until the system is matched.
      def refuse_system_qualified_tokens!
        %i[category code].each do |name|
          next unless params[name].to_s.include?("|")

          return refuse_search_parameter(name, "a code without a system")
        end
      end

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
