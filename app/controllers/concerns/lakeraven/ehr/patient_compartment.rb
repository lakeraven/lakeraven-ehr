# frozen_string_literal: true

module Lakeraven
  module EHR
    # Patient-compartment enforcement for clinical endpoints.
    #
    # Naming a patient in a parameter is a usability rule, not a security
    # control — ANYWHERE it appears. Two rounds of review found the same defect
    # through two different doors:
    #
    #   round 2: `GET /Observation?patient=1` from a token bound to 999 read
    #            patient 1's observations, because the index only REQUIRED the
    #            parameter and then trusted it.
    #   round 3: `POST /transitions_of_care?patient_dfn=1` from a token bound
    #            to 999 returned patient 1's complete C-CDA — name, DOB,
    #            address, allergies, conditions, medications — because round
    #            2's fix bound `:index` and nothing else.
    #
    # So the binding is declared, not inferred from the verb: `:index` binds on
    # the `patient` search parameter automatically, and any other action binds
    # by naming its own parameter with `compartment_bound`.
    module PatientCompartment
      extend ActiveSupport::Concern

      class_methods do
        # Bind `actions` to the patient compartment named by `param`.
        #
        # Declared per action, never inferred. Nothing is registered by merely
        # including this concern: an earlier version auto-bound `:index`, which
        # silently did nothing on controllers that have no index — and Rails'
        # `raise_on_missing_callback_actions` was what caught it.
        #
        # A patient-bound token may only name its OWN compartment, and an
        # action that names no patient at all is a cross-patient operation by
        # definition, so a bound token cannot issue one. Unbound (user/ or
        # system/) tokens are unaffected.
        #
        # `require_param: true` additionally rejects a missing parameter with a
        # 400 for EVERY caller — the search-usability rule that clinical
        # indexes already had. It is not a security control and never was.
        def compartment_bound(*actions, param:, require_param: false)
          before_action(only: actions) do
            enforce_declared_compartment!(param, require_param: require_param)
          end
        end
      end

      private

      def enforce_declared_compartment!(param, require_param: false)
        return render_missing_patient_param if require_param && params[param].blank?

        authorize_patient_search!(extract_patient_dfn(params[param]))
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
