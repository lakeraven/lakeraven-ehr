# frozen_string_literal: true

module Lakeraven
  module EHR
    # Forward one of the user's notifications to a colleague, with an optional
    # comment (rpms-ux S-SGN-02.4), through BEHOXQ FORWARD as VueCentric's
    # Notifications tab does. The colleague is chosen from a search of RPMS's
    # users, never typed as a number: the forward is sent only to a DUZ the
    # same search, run again here, lists. They get their own copy, with the
    # comment; the user keeps theirs.
    #
    # The search posts (find), as the other look-ups do (#722), and keeps what
    # was entered.
    class NotificationForwardsController < WebController
      # Throttled like every credentialed route (#498).
      rate_limit only: %i[new find create]

      include RpmsUnavailableRendering
      include NotificationAccess

      before_action :load_notification!

      # GET /notifications/:alert_id/forward
      def new
        @forward = NotificationForward.new
        @recipients = []
      end

      # POST /notifications/:alert_id/forward/find
      def find
        @forward = NotificationForward.new(forward_params)
        @recipients = search
        render :new
      end

      # POST /notifications/:alert_id/forward
      def create
        @forward = NotificationForward.new(forward_params)
        @recipients = search
        @recipient = @recipients.find { |r| r[:duz] == @forward.recipient_duz } if @forward.recipient_duz.present?
        @forward.validate
        if @forward.recipient_duz.present? && @recipient.nil?
          @forward.errors.add(:recipient_duz, "is not one the search lists: find your colleague by name and choose them")
        end
        return render(:new, status: :unprocessable_content) if @forward.errors.any?

        result = NotificationsGateway.forward(@notification[:alert_id], to: @recipient[:duz], comment: @forward.comment)
        if result.done?
          redirect_to notifications_path, notice: "Notification forwarded to #{@recipient[:name]}."
        else
          flash.now[:alert] = result.refused? ? "RPMS did not forward this notification." : "RPMS did not confirm the forward. Check with your colleague before sending it again."
          render :new, status: (result.refused? ? :unprocessable_content : :service_unavailable)
        end
      end

      private

      def load_notification!
        @notification = NotificationsGateway.find(params[:alert_id])
        redirect_to(notifications_path, alert: NOT_LISTED) unless @notification
      end

      def search
        NotificationsGateway.recipients(params[:recipient_search], except: session[:duz])
      end

      def forward_params
        params.fetch(:forward, {}).permit(:recipient_duz, :comment)
      end

      # The search reads users' names, nothing is sent.
      def audit_action = action_name == "create" ? "C" : "R"
    end
  end
end
