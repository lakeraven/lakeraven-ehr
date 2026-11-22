# frozen_string_literal: true

module Lakeraven
  module EHR
    # Whether RPMS lets the signed-in user open a record (#613): BPRM 6.0's
    # sensitive-patient check (AG_CheckSPTAccessQ and friends), asked before
    # the record opens, through SensitiveRecordGateway.
    #
    # PTSEC^DGSEC4's code decides; everything it does not name is refused:
    #
    #   0        not sensitive: open
    #   1        PTSEC logged the access, no acknowledgement needed: open
    #   2        warn; the user acknowledges (acknowledge_sensitive=1) on a
    #            second request, which asks again, then NOTICE^DGSEC4 action 3
    #            must answer success before the record opens
    #   3, 4, 5  denied, with RPMS's reason; an acknowledgement changes nothing
    #   other    -1, an undefined code, no answer, or an error: not opened
    #
    # RPMS serving the check or the bulletin, but not to this user, is its
    # own answer: the gem's RpmsRpc::Client::RpcRefusedError, raised when the
    # broker's error reads as a refusal (rpms-rpc lib/rpms_rpc/client.rb,
    # REFUSED_PATTERN: CIA "Access denied for remote procedure: NAME", XWB
    # "The remote procedure NAME is not registered to the option OPT."). The
    # user's account is not set up for the check. That is a determined "no",
    # 403, and retrying will not change it.
    #
    # The gem's ContextRefusedError is not mapped here: it raises that only at
    # CIA sign-on (#501), never from RpmsRpc::DgSensitive, so it is not an
    # answer about this check. Any other RpmsRpc::Error, a plain RpcError
    # included (an XWB "Failed to create context", a dropped call), is no
    # answer: unavailable, 503. So is an error that is not RPMS's at all.
    #
    # Every refusal goes through refuse_sensitive_record: it notes the reason
    # for the audit row (AuditableClinicalAccess#note_audit_denial), so the
    # attempt is filed as a refusal, not an open; it closes the session's open
    # record when that is the record refused, since RPMS has just said no to
    # it; and it renders the page. RPMS's message lines are its own text,
    # shown escaped; nothing about the patient is read or shown before the open.
    module SensitiveRecordAccess
      extend ActiveSupport::Concern

      ACKNOWLEDGEMENT_PARAM = :acknowledge_sensitive
      ACKNOWLEDGED = "1"
      OPENS = [ 0, 1 ].freeze
      NEEDS_ACKNOWLEDGEMENT = 2
      DENIED = [ 3, 4, 5 ].freeze
      TEMPLATE = "lakeraven/ehr/patient_contexts/sensitive_record"
      # A warning or a denial is RPMS's determined "not yet" or "no": 403, as
      # the record-not-open page is. No usable answer is 503: nobody decided.
      STATUS_BY_OUTCOME = {
        acknowledge: :forbidden,
        denied: :forbidden,
        account_not_set_up: :forbidden,
        unavailable: :service_unavailable
      }.freeze
      ACCOUNT_NOT_SET_UP_REASON =
        "sensitive record check: RPMS refused the user's account the #{SensitiveRecordGateway::OPTION} option"

      private

      # True when the record may open. Otherwise renders the refusal and
      # returns false. `dfn` is the route segment; RPMS is asked about the
      # canonical record it names (the gem refuses leading zeros).
      def sensitive_record_cleared?(dfn)
        @sensitive_dfn = dfn
        @sensitive_record = record = Patient.canonical_dfn(dfn)
        answer = ask_sensitive_record(record)
        return false if answer == :failed

        code = answer.is_a?(Hash) ? answer[:result] : nil
        messages = answer.is_a?(Hash) ? Array(answer[:messages]) : []

        return true if OPENS.include?(code)
        return acknowledged_sensitive_open?(record, messages) if code == NEEDS_ACKNOWLEDGEMENT
        return refuse_sensitive_record(:denied, messages, "sensitive record: RPMS denied access (code #{code})") if DENIED.include?(code)

        refuse_sensitive_record(:unavailable, messages, "sensitive record check: RPMS gave no usable answer")
      end

      def ask_sensitive_record(record)
        SensitiveRecordGateway.check(record)
      rescue ::RpmsRpc::NotConfiguredError
        raise # no connection of its own: RpmsUserScope ends the session
      rescue ::RpmsRpc::Client::RpcRefusedError => e
        refuse_account_not_set_up(e, "check")
      rescue StandardError => e
        # A plain RpcError (XWB "Failed to create context", a dropped call)
        # or an error that is not RPMS's: nobody decided, 503.
        refuse_after_error(e, "check")
      end

      # Code 2. The acknowledgement is honoured only on top of the check this
      # request has just made, and only RPMS's own "logged and sent" opens.
      def acknowledged_sensitive_open?(record, messages)
        unless params[ACKNOWLEDGEMENT_PARAM].to_s == ACKNOWLEDGED
          return refuse_sensitive_record(:acknowledge, messages, "sensitive record: acknowledgement required")
        end

        logged = record_sensitive_acknowledgement(record)
        return false if logged == :failed
        return true if logged.is_a?(Hash) && logged[:success] == true

        refuse_sensitive_record(:unavailable, [], "sensitive record bulletin: RPMS did not record the acknowledged access")
      end

      def record_sensitive_acknowledgement(record)
        SensitiveRecordGateway.record_acknowledged_access(record)
      rescue ::RpmsRpc::NotConfiguredError
        raise
      rescue ::RpmsRpc::Client::RpcRefusedError => e
        refuse_account_not_set_up(e, "bulletin")
      rescue StandardError => e
        # As for the check: a plain RpcError or a non-RPMS error is 503.
        refuse_after_error(e, "bulletin")
      end

      # Renders the refusal and returns :failed, for the callers above.
      def refuse_account_not_set_up(error, call)
        Rails.logger.warn("[sensitive-record] #{call} refused: #{error.class}")
        refuse_sensitive_record(:account_not_set_up, [], ACCOUNT_NOT_SET_UP_REASON)
        :failed
      end

      # The check or the bulletin raised something other than a refusal.
      # The open is refused here, rendered rather than re-raised: with the
      # cookie session store a raised request drops its session changes, so
      # a re-raise would leave the refused record open in the browser. Only
      # the error's class is logged and audited, never its message, which
      # may carry what RPMS or the code below said about the patient.
      def refuse_after_error(error, call)
        Rails.logger.error("[sensitive-record] #{call} raised #{error.class}")
        refuse_sensitive_record(:unavailable, [], "sensitive record #{call}: call failed (#{error.class.name})")
        :failed
      end

      # The one way a sensitive-record open is refused.
      def refuse_sensitive_record(outcome, messages, reason)
        note_audit_denial(reason)
        close_refused_patient_context!
        @sensitive_outcome = outcome
        @sensitive_messages = messages.map(&:to_s)
        render template: TEMPLATE, formats: :html, status: STATUS_BY_OUTCOME.fetch(outcome)
        false
      end

      # The session stops holding the refused record, however either side
      # spells it ("03" is patient 3). Another open record is not touched.
      def close_refused_patient_context!
        return if @sensitive_record.blank?
        return unless Patient.canonical_dfn(session[ClinicianPatientContext::SESSION_KEY]) == @sensitive_record

        close_patient_context!
      end
    end
  end
end
