# frozen_string_literal: true

module Lakeraven
  module EHR
    class ObservationsController < ApplicationController
      # Org-bound credentials: authorization binds to the patient RESOLVED
      # from ?patient=, at the result level (SmartAuthentication).
      organization_scope :resolved_patient, only: :index, dfn_param: :patient
      before_action :require_patient_param, only: :index

      def index
        dfn = extract_patient_dfn(params[:patient])
        raw = Observation.for_patient(dfn)
        observations = Observation.from_vital_hashes(raw, patient_dfn: dfn)
        observations += Lakeraven::EHR.configuration.supplemental_observations_for(dfn)
        observations = filter_observations(observations)
        observations = sort_observations(observations)
        render_bundle(observations.map(&:to_fhir), includes: provenance_includes(observations))
      end

      def show
        render_not_found("Observation", params[:id])
      end

      private

      def require_patient_param
        return if params[:patient].present?

        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "required",
          diagnostics: "Search parameter 'patient' is required"
        )
      end

      def extract_patient_dfn(param)
        param.to_s.delete_prefix("Patient/")
      end

      def filter_observations(observations)
        observations = observations.select { |o| o.category == params[:category] } if params[:category].present?
        if params[:code].present?
          codes = params[:code].split(",")
          observations = observations.select { |o| codes.include?(o.code) }
        end
        filter_by_date(observations)
      end

      # FHIR date search parameter (Vardana profile section 4:
      # `date=ge{date}`). Supports the comparison prefixes on
      # effectiveDateTime; repeated date params AND together.
      DATE_PREFIXES = %w[ge le gt lt eq].freeze

      def filter_by_date(observations)
        Array(params[:date]).each do |expression|
          prefix = DATE_PREFIXES.find { |p| expression.start_with?(p) } || "eq"
          boundary = parse_search_date(expression.delete_prefix(prefix))
          next unless boundary

          observations = observations.select do |o|
            date = o.effective_datetime&.to_date
            date && date_matches?(date, prefix, boundary)
          end
        end
        observations
      end

      def parse_search_date(value)
        Date.parse(value)
      rescue ArgumentError, TypeError
        nil
      end

      def date_matches?(date, prefix, boundary)
        case prefix
        when "ge" then date >= boundary
        when "le" then date <= boundary
        when "gt" then date > boundary
        when "lt" then date < boundary
        else date == boundary
        end
      end

      # `_sort=date` / `_sort=-date` on effectiveDateTime; observations
      # without one sort last either way.
      def sort_observations(observations)
        return observations unless %w[date -date].include?(params[:_sort])

        sorted, undated = observations.partition { |o| o.effective_datetime.present? }
        sorted = sorted.sort_by(&:effective_datetime)
        sorted = sorted.reverse if params[:_sort] == "-date"
        sorted + undated
      end

      # `_revinclude=Provenance:target` (US Core's mechanism for provenance,
      # and how Vardana distinguishes office-measured from patient-reported
      # values). Provenance rides along as search.mode "include".
      def provenance_includes(observations)
        return [] unless params[:_revinclude] == "Provenance:target"

        observations.flat_map do |o|
          ProvenanceStore.instance.for_target("Observation", o.ien.to_s).map(&:to_fhir)
        end
      end
    end
  end
end
