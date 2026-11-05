# frozen_string_literal: true

module Lakeraven
  module EHR
    # The signed-in clinician's RPMS notifications (rpms-ux S-SGN-02.1), each
    # with its patient, and a way to open that patient's chart. The dashboard
    # counts them and links here (#874). A notification RPMS lists as one the
    # user can delete can be removed from their list (S-SGN-02.2); one it
    # does not offers no Remove (S-SGN-02.3). Forwarding is
    # NotificationForwardsController (S-SGN-02.4).
    #
    # The list names patients, so it takes the chart's Patient read (CIAV
    # VUECENTRIC, SessionScopePolicy), as the patient bar's search does.
    # Every RPC runs as the signed-on user, on their own connection.
    class NotificationsController < WebController
      # Throttled like every credentialed route (#498).
      rate_limit only: %i[index destroy]

      include RpmsUnavailableRendering
      include NotificationAccess

      def index
        @notifications = NotificationsGateway.inbox
        @texts = @notifications.to_h { |n| [ n[:alert_id], text_for(n[:alert_id]) ] }
      end

      # DELETE /notifications/:alert_id
      def destroy
        @notification = NotificationsGateway.find(params[:alert_id])
        return redirect_to(notifications_path, alert: NOT_LISTED) unless @notification

        result = NotificationsGateway.remove(@notification[:alert_id])
        if result.done?
          redirect_to notifications_path, notice: "Notification removed#{" for #{@notification[:patient_name]}" if @notification[:patient_name]}."
        elsif result.refused?
          redirect_to notifications_path, alert: "RPMS did not remove this notification. It stays in your list until the work it asks for is done."
        else
          redirect_to notifications_path, alert: "RPMS did not confirm the removal. Check your list before trying again."
        end
      end

      private

      # The comment or long text RPMS holds with a notification, or :unread
      # when RPMS does not answer: the list still shows, and says so.
      def text_for(alert_id)
        NotificationsGateway.text(alert_id)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[notifications] text read raised #{e.class}")
        :unread
      end
    end
  end
end
