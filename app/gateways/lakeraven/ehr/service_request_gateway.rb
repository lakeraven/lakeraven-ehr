# frozen_string_literal: true

require "rpms_rpc/api/referral"

module Lakeraven
  module EHR
    class ServiceRequestGateway
      def self.for_patient(dfn)
        CapabilityGuard.ensure!(:prc_referrals)
        RpmsRpc::Referral.for_patient(dfn.to_s)
      end

      # The referrals still pending at the facility, for every patient: STATUS
      # OF REFERRAL ACTIVE or APPROVED, DATE INITIATED in window (a Range of
      # Dates), oldest first. Stock BMC SEARCH REFERRAL by date, read as the
      # signed-on user (RpmsRpc::Referral.pending, rpms-rpc#589).
      def self.pending(window)
        CapabilityGuard.ensure!(:prc_referrals)
        RpmsRpc::Referral.pending(from: window.begin, to: window.end)
      end

      # Demo prototype (#990; not in the December build). A confirmed outside-app
      # follow-up filed on the RPMS referral: the date of service and a case
      # note, through BMC UPDATE REFERRAL (RpmsRpc::Referral.record_follow_up,
      # rpms-rpc#722, not yet run live). Returns the gem's
      # { success:, message:, error: } hash.
      def self.record_follow_up(ien, appointment_on:, case_note:)
        CapabilityGuard.ensure!(:prc_referrals)
        RpmsRpc::Referral.record_follow_up(ien.to_s, appointment_on: appointment_on, case_note: case_note)
      end

      # What RPMS now holds for that referral: status, date of service (1106,
      # FileMan internal) and its case notes (RpmsRpc::Referral.follow_up_state).
      def self.follow_up_state(ien)
        CapabilityGuard.ensure!(:prc_referrals)
        RpmsRpc::Referral.follow_up_state(ien.to_s)
      end

      def self.create(dfn, params)
        CapabilityGuard.ensure!(:prc_referrals)
        RpmsRpc::Referral.create(dfn.to_s, params)
      end

      # Cancel a referral: RCIS files its status as cancelled through BMC
      # REFERRAL STATUS UPDATE (RpmsRpc::Referral.cancel, rpms-rpc #380). RCIS
      # has no delete (the BMCRPC DELREFRL name the old delete sent is in no
      # option on a built image), and the routine files no reason, so this
      # takes none: a reason asked for and then dropped would look recorded.
      # A refusal or a broker error comes back as a failure with its message.
      def self.cancel(ien)
        CapabilityGuard.ensure!(:prc_referrals)
        result = RpmsRpc::Referral.cancel(ien.to_s)
        if result[:success]
          { success: true, message: "Referral cancelled", ien: ien }
        else
          { success: false, error: result[:message] || "Cancellation failed", ien: ien }
        end
      rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
        { success: false, error: PhiSanitizer.sanitize_message(e.message), ien: ien }
      end
    end
  end
end
