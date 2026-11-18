# frozen_string_literal: true

module Lakeraven
  module EHR
    # A form that charts on one of the patient's open visits, through an RPC
    # RPMS files as the connection's signed-on user (rpms-ux S-TRI). The
    # gates, in order: a sign-on (the session's SMART token and DUZ), the
    # "visit.chart" capability, the token's patient compartment and the
    # session's deliberate patient context, and a token DUZ that is the
    # session's. The host names what it charts (charted_thing) and sets
    # @write_outcome to :written, :nothing_written or :unknown.
    module VisitCharting
      extend ActiveSupport::Concern
      include BrowserSmartAuthentication
      include ClinicianPatientContext
      include OpenVisits

      UNKNOWN_OUTCOME_ERRORS = [ ::RpmsRpc::Error, IOError, SystemCallError ].freeze

      included do
        rate_limit only: %i[new create]

        before_action :require_authentication
        before_action :authenticate_smart_token!
        before_action -> { require_capability!("visit.chart") }
        before_action :load_patient
        before_action :enforce_token_patient_context!
        before_action :enforce_patient_context!
        before_action :require_clinician_credential!
      end

      private

      def load_patient
        @dfn = params[:dfn]
      end

      def enforce_token_patient_context! = authorize_patient_context!(params[:dfn])

      # The connection files as its own user, so the token's DUZ must be the
      # session's: the two are minted together.
      def require_clinician_credential!
        duz = current_duz
        return true if duz.present? && duz.to_s == session[:duz].to_s

        render_forbidden("Charting on a visit requires a clinician sign-on")
        false
      end

      def refuse(message)
        @refusal = message
        render :new, status: :unprocessable_entity
      end

      def fhir_resource_type = "Patient"

      def direct_audit_identifier
        Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
      end

      def audit_outcome
        @write_outcome == :unknown ? "8" : super
      end

      # The write is already in RPMS when the audit row fails after it: say
      # so, so it is not entered twice.
      def render_unrecorded_access_denial
        return super unless @write_outcome == :written

        Rails.logger.error("ERROR [visit_charting] #{charted_thing} recorded in RPMS but this access could not be audited")
        render plain: "Service Unavailable: RPMS recorded the #{charted_thing}, but this access could not be " \
                      "audited. Do not enter it again.", status: :service_unavailable
      end
    end
  end
end
