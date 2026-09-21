# frozen_string_literal: true

module Lakeraven
  module EHR
    # Patient-context binding for the SESSION-authenticated web surface.
    #
    # The FHIR surface binds a patient-scoped token to its compartment
    # (SmartAuthentication#authorize_patient_context!). The web surface has no
    # token, so it binds the session: a clinician reads a patient's record only
    # after explicitly OPENING that record, which is a deliberate act (a CSRF
    # -protected POST) and is audited under the acting DUZ. That is the VistA /
    # CPRS model — patient selection, then the chart.
    #
    # The binding is never established as a side effect of the read it guards;
    # a gate that opens itself is not a gate.
    #
    # What this is NOT: a treating-relationship check. The engine has no
    # provider-patient relationship data and no sensitive-patient (DG SECURITY)
    # feed yet, so this makes cross-patient access deliberate and attributable
    # rather than impossible. Real relationship-based authorization is tracked
    # separately — do not read this concern as more than it is.
    module ClinicianPatientContext
      extend ActiveSupport::Concern

      SESSION_KEY = :open_patient_dfn

      private

      def open_patient_context!(dfn)
        session[SESSION_KEY] = dfn.to_s
      end

      def close_patient_context!
        session.delete(SESSION_KEY)
      end

      def patient_context_open?(dfn)
        dfn.present? && session[SESSION_KEY].to_s == dfn.to_s
      end

      # Fails closed with a page that names the reason and offers the explicit
      # open — "we could not determine you opened this record", not a blank 403.
      def enforce_patient_context!
        return true if patient_context_open?(params[:dfn])

        @dfn = params[:dfn]
        render template: "lakeraven/ehr/patient_contexts/new", status: :forbidden
        false
      end
    end
  end
end
