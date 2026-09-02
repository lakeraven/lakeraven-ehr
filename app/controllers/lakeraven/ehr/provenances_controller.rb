# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 Provenance — distinguishes office-measured from patient-reported
    # observation values (Vardana source-system profile checklist item 10).
    # Derived per-request from the observation read path; see
    # FHIR::ObservationProvenanceSerializer for the RPMS/PCC field grounding.
    #
    # Search: `patient` (with optional `target` filter), or `target` alone
    # when the observation id embeds the patient DFN (the deterministic
    # "vital-{dfn}-..." ids the vitals path emits).
    class ProvenancesController < ApplicationController
      before_action :require_search_param, only: :index

      def index
        target_id = extract_target_id
        dfn = resolve_dfn(target_id)

        if dfn.blank?
          return render_operation_outcome(
            status: :bad_request,
            severity: "error",
            code: "required",
            diagnostics: "Search parameter 'patient' is required when the target id does not identify a patient"
          )
        end

        observations = observations_for(dfn)
        observations = observations.select { |o| o.ien == target_id } if target_id.present?
        render_bundle(observations.filter_map { |o| FHIR::ObservationProvenanceSerializer.call(o) })
      end

      def show
        observation_id = params[:id].to_s.delete_prefix("prov-")
        dfn = dfn_embedded_in(observation_id)
        return render_not_found("Provenance", params[:id]) if dfn.blank?

        observation = observations_for(dfn).find { |o| o.ien == observation_id }
        provenance = observation && FHIR::ObservationProvenanceSerializer.call(observation)
        return render_not_found("Provenance", params[:id]) if provenance.nil?

        render_fhir(provenance)
      end

      private

      def require_search_param
        return if params[:patient].present? || params[:target].present?

        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "required",
          diagnostics: "Search parameter 'patient' or 'target' is required"
        )
      end

      def extract_target_id
        params[:target].to_s.delete_prefix("Observation/").presence
      end

      def resolve_dfn(target_id)
        params[:patient].to_s.delete_prefix("Patient/").presence || dfn_embedded_in(target_id)
      end

      # Derived vitals ids are "vital-{dfn}-{type}[-{timestamp}]"; a raw IEN
      # embeds no DFN, so those lookups need the patient param.
      def dfn_embedded_in(observation_id)
        observation_id.to_s[/\Avital-(\d+)-/, 1]
      end

      def observations_for(dfn)
        Observation.from_vital_hashes(Observation.for_patient(dfn), patient_dfn: dfn)
      end
    end
  end
end
