# frozen_string_literal: true

module Lakeraven
  module EHR
    # The vaccines a patient is due for, from RPMS's Immunization package
    # forecast, the due list VueCentric's immunization component shows
    # (lakeraven-ehr#865). The forecast is the package's call to its outside
    # forecaster. When the package produced none it says why, and the page
    # shows that reason: it never shows "nothing due" for a forecast that was
    # not made.
    #
    # Same credential as the chart: a SMART token with Immunization read, the
    # token's patient compartment, and the session's deliberate patient
    # context. A backend without the IHS Immunization package says the
    # feature is unavailable (#647).
    class ImmunizationForecastsController < WebController
      include BrowserSmartAuthentication
      include ClinicianPatientContext
      include FeatureUnavailableRendering
      include RpmsUnavailableRendering

      rate_limit only: :show

      IMMUNIZATION_RESOURCE = "Immunization"

      before_action :authenticate_smart_token!
      before_action :authorize_immunization_read!
      before_action :load_patient
      before_action :enforce_token_patient_context!
      before_action :enforce_patient_context!

      def show
        @due = ImmunizationGateway.forecast(@dfn)
      rescue ::RpmsRpc::Immunization::ForecastError => e
        Rails.logger.info("[immunization_forecast] no forecast: package error #{e.code}")
        @no_forecast = { reason: e.package_message, code: e.code }
      end

      private

      def authorize_immunization_read!
        return true if can_read?(IMMUNIZATION_RESOURCE)

        render_forbidden("Insufficient scope to read #{IMMUNIZATION_RESOURCE}")
        false
      end

      def load_patient
        @dfn = params[:dfn]
      end

      def fhir_resource_type = "Patient"

      def direct_audit_identifier
        Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
      end
    end
  end
end
