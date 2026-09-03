# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 Provenance — distinguishes office-measured observation values
    # from values captured outside an in-person visit (Vardana checklist
    # item 10). Derived per-request from the measurement read path; see
    # FHIR::ObservationProvenanceSerializer for the RPMS/PCC grounding.
    #
    # Search: `patient` lists provenance for that patient's observations;
    # `target=Observation/{ien}` resolves the single measurement by its
    # V MEASUREMENT IEN (the read supplies the patient itself, so no
    # `patient` parameter is required). Ids are `prov-{measurement-ien}`.
    class ProvenancesController < ApplicationController
      before_action :require_search_param, only: :index

      def index
        target_id = extract_target_id

        observations =
          if target_id.present?
            observation = find_observation(target_id)
            observation ? [ observation ] : []
          else
            observations_for(params[:patient].to_s.delete_prefix("Patient/"))
          end

        if params[:patient].present? && target_id.present?
          dfn = params[:patient].to_s.delete_prefix("Patient/")
          observations = observations.select { |o| o.patient_dfn.to_s == dfn }
        end

        render_bundle(observations.filter_map { |o| FHIR::ObservationProvenanceSerializer.call(o) })
      end

      def show
        observation_id = params[:id].to_s.delete_prefix("prov-")
        observation = find_observation(observation_id)
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

      # By-IEN read (rpms-rpc Measurement.find — DDR GETS ENTRY DATA on
      # #9000010.01, which carries the patient DFN in field .02).
      def find_observation(measurement_ien)
        row = ObservationGateway.find(measurement_ien)
        return nil if row.nil?

        Observation.from_measurement_hashes([ row ], patient_dfn: row[:patient_dfn].to_s).first
      end

      def observations_for(dfn)
        Observation.from_measurement_hashes(Observation.for_patient(dfn), patient_dfn: dfn)
      end
    end
  end
end
