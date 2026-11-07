# frozen_string_literal: true

module Lakeraven
  module EHR
    # What the notifications pages share (NotificationsController,
    # NotificationForwardsController): a signed-in user with the chart's
    # Patient read, since a notification names its patient; and an audit row
    # that names that patient when the request acts on one notification.
    module NotificationAccess
      extend ActiveSupport::Concern

      NOT_LISTED = "That notification is no longer in your list."

      included do
        before_action :require_authentication
        before_action :require_patient_read!
      end

      private

      def require_patient_read!
        return if patient_search_allowed?

        note_audit_denial("browser access refused: no Patient read")
        render "lakeraven/ehr/shared/forbidden", formats: :html, status: :forbidden
      end

      # The audited entity is the patient the notification is about, once the
      # action has found it in the user's list; the list itself names no one
      # patient. The alert ID is not a record identifier and is never one.
      def fhir_resource_type = "Patient"
      def direct_audit_identifier = @notification&.dig(:patient_dfn)&.to_s
    end
  end
end
