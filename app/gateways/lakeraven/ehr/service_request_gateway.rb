# frozen_string_literal: true

require "rpms_rpc/api/referral"

module Lakeraven
  module EHR
    class ServiceRequestGateway
      DELETABLE_STATUSES = %w[draft pending submitted].freeze

      def self.for_patient(dfn)
        RpmsRpc::Referral.for_patient(dfn.to_s)
      end

      def self.delete(ien, reason: nil)
        referral = find_referral(ien)
        return { success: false, error: "Referral not found", ien: ien } unless referral

        status = referral[:status]&.downcase || "unknown"

        unless DELETABLE_STATUSES.include?(status)
          return { success: false, error: "Cannot delete #{status} referral", ien: ien }
        end

        if status != "draft" && reason.blank?
          return { success: false, error: "Reason required for #{status} referral", ien: ien }
        end

        result = RpmsRpc::Referral.delete(ien, reason: reason)
        if result && result[:success]
          { success: true, message: "Referral deleted", ien: ien }
        else
          { success: false, error: result&.dig(:message) || "Delete failed", ien: ien }
        end
      rescue => e
        { success: false, error: PhiSanitizer.sanitize_message(e.message), ien: ien }
      end

      def self.cancel(ien, reason: nil)
        return { success: false, error: "Reason required for cancellation" } if reason.blank?

        referral = find_referral(ien)
        return { success: false, error: "Referral not found" } unless referral

        result = RpmsRpc::Referral.delete(ien, reason: reason)
        if result && result[:success]
          { success: true, message: "Referral cancelled", ien: ien }
        else
          { success: false, error: result&.dig(:message) || "Cancellation failed", ien: ien }
        end
      rescue => e
        { success: false, error: PhiSanitizer.sanitize_message(e.message), ien: ien }
      end

      def self.deletable?(ien)
        referral = find_referral(ien)
        return false unless referral

        DELETABLE_STATUSES.include?(referral[:status]&.downcase)
      end

      def self.find_referral(ien)
        RpmsRpc::Referral.find(ien.to_s)
      end
      private_class_method :find_referral
    end
  end
end
