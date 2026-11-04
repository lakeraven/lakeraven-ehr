# frozen_string_literal: true

module Lakeraven
  module EHR
    # The signed-in clinician's RPMS notifications (rpms-ux S-SGN-02.1), each
    # with its patient, and a way to open that patient's chart. The dashboard
    # counts them and links here (#874).
    #
    # The list names patients, so it takes the chart's Patient read (CIAV
    # VUECENTRIC, SessionScopePolicy), as the patient bar's search does.
    class NotificationsController < WebController
      include RpmsUnavailableRendering

      before_action :require_authentication
      before_action :require_patient_read!

      def index
        @notifications = NotificationsGateway.inbox
      end

      private

      def require_patient_read!
        return if patient_search_allowed?

        note_audit_denial("browser access refused: no Patient read")
        render "lakeraven/ehr/shared/forbidden", formats: :html, status: :forbidden
      end

      # The list reads patients' names; it opens no chart.
      def audit_action = "R"
      def fhir_resource_type = "Patient"
    end
  end
end
