# frozen_string_literal: true

require "rpms_rpc/api/busa"

module Lakeraven
  module EHR
    # The BUSA security audit entry BPRM 6.0 writes for an audited action
    # (Core_SetBusaAuditLogQ), through BUSA LOG SECURITY AUDIT ENTRY
    # (RpmsRpc::Busa.log_security_audit, option BUSARPC). The one audited
    # action of this slice is a saved registration edit (lakeraven-ehr#617).
    #
    # BUSA takes the user from the broker session (DUZ), so the user is never
    # sent. The entry is CAT|ACTION|CALL|DESC|DETAIL: category P (patient),
    # action E (edit), this app's call name, a fixed description that holds no
    # PHI, and the DFN as detail.
    #
    # Only RESULT 1 is a confirmed entry. The capture in rpms-rpc
    # test/fixtures/captured_replies/busa-log.yml (patient_detail/1), from
    # release bcer-9.0-20261119-f67498c-ydb, shows the summary of a
    # patient-related event filed, then the patient-detail row naming the DFN
    # refused with 0^ and no message. No reply is captured yet for this
    # repo's pinned build (bcer-9.0-20261113-3f5487a-ydb). So a result that is not
    # 1 does not show that nothing was filed: it is an entry RPMS did not
    # confirm, and the caller records it as a gap ("BUSA entry not confirmed").
    #
    # A DFN is sent only in the gem's canonical form (RpmsRpc::Scheduling
    # canonical_id): a positive Integer, or a String of digits with no leading
    # zero. Anything else is refused before any call, and never normalised.
    #
    # Never raises: the RPMS change the entry follows has already happened.
    class SecurityAuditGateway
      CALL = "LAKERAVEN EHR REGISTRATION"
      CATEGORY = "P"
      ACTION = "E"

      Result = Data.define(:filed, :reason) do
        def filed? = filed
      end

      FILED = Result.new(filed: true, reason: nil)

      def self.record_patient_edit(dfn:, description:, via: ::RpmsRpc::Busa)
        detail = patient_detail(dfn)
        return not_filed("no patient: the DFN is not a positive whole number") if detail.nil?
        return not_filed("the description contains the BUSA piece delimiter") if description.to_s.include?(::RpmsRpc::Busa::PIPE)

        reply = via.log_security_audit(category: CATEGORY, action: ACTION, call: CALL,
                                       description: description.to_s, detail: detail)
        interpret(reply)
      rescue StandardError => e
        Rails.logger.error("[busa] security audit entry raised #{e.class}; not filed")
        not_filed("#{e.class.name} raised")
      end

      def self.patient_detail(dfn)
        case dfn
        when Integer then dfn.positive? ? dfn.to_s : nil
        when String then dfn.match?(/\A[1-9]\d*\z/) ? dfn : nil
        end
      end
      private_class_method :patient_detail

      def self.interpret(reply)
        return not_filed("RPMS did not answer") if reply.nil?
        return not_filed("RPMS gave no result") unless reply.is_a?(Hash) && reply.key?(:success)
        return FILED if reply[:success] == true

        message = reply[:message].to_s.strip
        not_filed(message.empty? ? "RPMS refused the entry without a reason" : "RPMS refused the entry: #{message}")
      end
      private_class_method :interpret

      def self.not_filed(reason) = Result.new(filed: false, reason: reason)
      private_class_method :not_filed
    end
  end
end
