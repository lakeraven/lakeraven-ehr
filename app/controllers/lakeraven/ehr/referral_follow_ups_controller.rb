# frozen_string_literal: true

module Lakeraven
  module EHR
    # Demo prototype (#989; not in the December build, synthetic data only).
    # The review queue for follow-ups registered outside apps post about
    # referrals (CommunicationsController). A user who works referrals
    # confirms or rejects each one. Confirming writes it to the RPMS referral
    # and reads it back (ReferralFollowUpWriteBack); rejecting writes nothing
    # to RPMS. Each decision records who made it and when, with an AuditEvent.
    class ReferralFollowUpsController < WebController
      rate_limit only: %i[index confirm reject retry]

      before_action :require_authentication
      before_action -> { require_capability!("referrals.work") }
      before_action :load_follow_up, only: %i[confirm reject retry]

      def index
        @pending = AppFollowUp.pending
        @reviewed = AppFollowUp.reviewed.limit(20)
      end

      def confirm
        return redirect_to(referral_follow_ups_path, alert: "That follow-up was already reviewed.") unless @follow_up.pending?

        decide!("confirmed")
        result = ReferralFollowUpWriteBack.call(@follow_up)
        if result.success
          redirect_to referral_follow_ups_path, notice: "Confirmed. Written to the RPMS referral and read back."
        else
          redirect_to referral_follow_ups_path, alert: "Confirmed, but the RPMS write failed: #{result.detail}"
        end
      end

      def reject
        return redirect_to(referral_follow_ups_path, alert: "That follow-up was already reviewed.") unless @follow_up.pending?

        decide!("rejected")
        redirect_to referral_follow_ups_path, notice: "Rejected. Nothing was written to RPMS."
      end

      # A confirmed follow-up whose RPMS write failed, tried again.
      def retry
        unless @follow_up.confirmed? && !@follow_up.written_back?
          return redirect_to(referral_follow_ups_path, alert: "Only a confirmed follow-up whose write failed can be retried.")
        end

        result = ReferralFollowUpWriteBack.call(@follow_up)
        flash_key = result.success ? :notice : :alert
        redirect_to referral_follow_ups_path, flash_key => (result.success ? "Written to the RPMS referral and read back." : "The RPMS write failed again: #{result.detail}")
      end

      private

      def load_follow_up
        @follow_up = AppFollowUp.find_by(id: params[:id])
        render plain: "Not found", status: :not_found unless @follow_up
      end

      def decide!(status)
        @follow_up.update!(status: status, reviewed_by_duz: session[:duz].to_s,
                           reviewed_by_name: session[:user_name].presence || "DUZ #{session[:duz]}",
                           reviewed_at: Time.current)
        AppFollowUpAudit.record!(@follow_up, action: "U", what: status, duz: @follow_up.reviewed_by_duz)
      end
    end
  end
end
