# frozen_string_literal: true

require "rpms_rpc/api/referral"

module Lakeraven
  module EHR
    class ServiceRequestGateway
      def self.for_patient(dfn)
        RpmsRpc::Referral.for_patient(dfn.to_s)
      end

      def self.create(dfn, params)
        RpmsRpc::Referral.create(dfn.to_s, params)
      end

      # Cancel a referral: RCIS files its status as cancelled through BMC
      # REFERRAL STATUS UPDATE (RpmsRpc::Referral.cancel, rpms-rpc #380). RCIS
      # has no delete (the BMCRPC DELREFRL name the old delete sent is in no
      # option on a built image), and the routine files no reason, so this
      # takes none: a reason asked for and then dropped would look recorded.
      # A refusal or a broker error comes back as a failure with its message.
      def self.cancel(ien)
        result = RpmsRpc::Referral.cancel(ien.to_s)
        if result[:success]
          { success: true, message: "Referral cancelled", ien: ien }
        else
          { success: false, error: result[:message] || "Cancellation failed", ien: ien }
        end
      rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
        { success: false, error: PhiSanitizer.sanitize_message(e.message), ien: ien }
      end

      # PRC referrals are IHS-only (#647).
      CapabilityGuard.protect(self, :prc_referrals, :for_patient, :create, :cancel)
    end
  end
end
