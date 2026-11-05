# frozen_string_literal: true

module Lakeraven
  module EHR
    # The referrals pending at the facility, for a user who works referrals
    # (#873): every patient's ACTIVE or APPROVED referral initiated in a date
    # window, the last 12 months unless the user chooses other dates. Read from
    # RPMS as the signed-on user (stock BMC SEARCH REFERRAL). Referrals are
    # RCIS, which only an IHS backend serves (prc_referrals, #647).
    class PendingReferralsController < WebController
      before_action :require_prc_referrals!
      before_action :require_authentication
      before_action -> { require_capability!("referrals.work") }

      # GET /referrals/pending?from=YYYY-MM-DD&to=YYYY-MM-DD
      def index
        @from = params[:from].to_s
        @to = params[:to].to_s
        @window, @window_error = PendingReferralWindow.parse(@from, @to)
        @referrals = read_pending(@window) if @window
      end

      private

      def require_prc_referrals!
        return if BackendRegistry.current.provides?(:prc_referrals)

        note_audit_denial("browser access refused: backend lacks prc_referrals")
        render plain: "Referrals are not available on this backend.", status: :not_found
      end

      # The rows, or :unread when RPMS does not answer: a failed read is said
      # so, never shown as an empty list. A refusal keeps RPMS's reason.
      def read_pending(window)
        ServiceRequestGateway.pending(window)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[referrals] pending referrals raised #{e.class}")
        @refusal = e.message if e.is_a?(::RpmsRpc::Client::RpcRefusedError)
        :unread
      end
    end
  end
end
