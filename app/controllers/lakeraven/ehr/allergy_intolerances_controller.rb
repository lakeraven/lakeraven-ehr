# frozen_string_literal: true

module Lakeraven
  module EHR
    class AllergyIntolerancesController < ApplicationController
      # Org-bound credentials: authorization binds to the patient RESOLVED
      # from ?patient=, at the result level (SmartAuthentication). #show
      # authorizes at the result level itself — the owning patient resolves
      # from the found allergy, never from a request parameter.
      organization_scope :resolved_patient, only: :index, dfn_param: :patient
      organization_scope :result_filtered, only: :show
      before_action :require_patient_param, only: :index

      def index
        dfn = extract_patient_dfn(params[:patient])
        render_bundle(allergies_for(dfn).map(&:to_fhir))
      end

      # Resolves the same records the search emits (wire + supplemental), so
      # every id a search returns is readable. Org-bound credentials are
      # authorized against the RESOLVED resource's owning patient: a foreign
      # patient's allergy id is a 403 (never disclosed), an unknown id a 404.
      def show
        allergy = resolve_allergy(params[:id])
        return render_not_found("AllergyIntolerance", params[:id]) unless allergy

        # Patient-context tokens read only their own compartment (403 on a
        # foreign patient's resource); org-bound credentials are authorized
        # against the resolved owner's organization.
        return unless authorize_patient_context!(allergy.patient_dfn)
        if organization_bound?
          return unless authorize_resolved_patient!(allergy.patient_dfn)
        end

        render_fhir(allergy.to_fhir)
      end

      private

      # Wire-path allergies (ORQQAL LIST) plus supplemental fixtures. Every
      # supplemental record is re-checked against the requested (and
      # authorized) patient before serving — a supplemental entry owned by
      # any other patient must never appear in this patient's results
      # (Configuration#supplemental_allergy_intolerances_for filters, and
      # the belt-and-braces select here keeps this controller safe even if
      # that seam changes).
      def allergies_for(dfn)
        wire = AllergyIntolerance.from_rpc_hashes(AllergyIntolerance.for_patient(dfn), patient_dfn: dfn)
        supplemental = Lakeraven::EHR.configuration.supplemental_allergy_intolerances_for(dfn)
        wire + supplemental.select { |a| a.patient_dfn.to_s == dfn.to_s }
      end

      # Allergy ids are deterministic ("allergy-<dfn>-<slug>", see
      # AllergyIntolerance.allergy_id and the supplemental fixture ids), so
      # the owning patient parses straight out of the id and the record
      # resolves through the exact source set the search serves.
      def resolve_allergy(id)
        match = id.to_s.match(/\Aallergy-(\d+)-/)
        return nil unless match

        allergies_for(match[1]).find { |a| a.ien.to_s == id.to_s }
      end

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
    end
  end
end
