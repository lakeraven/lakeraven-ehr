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
    # Only RESULT 1 is a filed entry. The live build (rpms-rpc
    # test/fixtures/captured_replies/busa-log.yml) files a system event, but
    # answers 0^ with no message for a patient-detail row naming a DFN; so a
    # not-filed result is expected there, and the caller records it as a gap.
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
        when String then dfn.match?(/\A\d+\z/) && dfn.to_i.positive? ? dfn.to_i.to_s : nil
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
