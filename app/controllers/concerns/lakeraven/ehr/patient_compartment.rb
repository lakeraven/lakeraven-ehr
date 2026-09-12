# frozen_string_literal: true

module Lakeraven
  module EHR
    # Patient-compartment enforcement for clinical search endpoints.
    #
    # Requiring a `patient` search parameter is a usability rule, not a
    # security control: every clinical index used to demand the parameter and
    # then trust whatever it said, so a `patient/Observation.read` token bound
    # to patient 999 read patient 1's observations by asking for them.
    # Compartment binding lived on PatientsController#show and nowhere else.
    #
    # This concern puts both in one place — the parameter is required, and a
    # patient-bound token may only name its own compartment.
    module PatientCompartment
      extend ActiveSupport::Concern

      included do
        before_action :require_patient_scoped_search!, only: :index
      end

      private

      def require_patient_scoped_search!
        return render_missing_patient_param if params[:patient].blank?

        authorize_patient_search!(patient_compartment_dfn)
      end

      # DFN named by the `patient` search parameter, with the FHIR reference
      # prefix stripped (`Patient/1` and `1` are the same compartment).
      def patient_compartment_dfn
        extract_patient_dfn(params[:patient])
      end

      def extract_patient_dfn(param)
        param.to_s.delete_prefix("Patient/")
      end

      def render_missing_patient_param
        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "required",
          diagnostics: "Search parameter 'patient' is required"
        )
      end
    end
  end
end
