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
    # Every refusal renders here and notes its reason for the audit row
    # (AuditableClinicalAccess#note_audit_denial), so the attempt is filed as
    # a refusal, not an open. RPMS's message lines are its own text, shown
    # escaped; nothing about the patient is read or shown before the open.
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
      STATUS_BY_OUTCOME = { acknowledge: :forbidden, denied: :forbidden, unavailable: :service_unavailable }.freeze

      private

      # True when the record may open. Otherwise renders the refusal and
      # returns false. `dfn` is the route segment; RPMS is asked about the
      # canonical record it names (the gem refuses leading zeros).
      def sensitive_record_cleared?(dfn)
        @sensitive_dfn = dfn
        record = Patient.canonical_dfn(dfn)
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
      rescue ::RpmsRpc::Error => e
        Rails.logger.error("[sensitive-record] check raised #{e.class}")
        refuse_sensitive_record(:unavailable, [], "sensitive record check: RPMS call failed (#{e.class.name})")
        :failed
      end

      # Code 2. The acknowledgement is honoured only on top of the check this
      # request has just made, and only RPMS's own "logged and sent" opens.
      def acknowledged_sensitive_open?(record, messages)
        unless params[ACKNOWLEDGEMENT_PARAM].to_s == ACKNOWLEDGED
          return refuse_sensitive_record(:acknowledge, messages, "sensitive record: acknowledgement required")
        end

        logged = record_sensitive_acknowledgement(record)
        return true if logged.is_a?(Hash) && logged[:success] == true

        refuse_sensitive_record(:unavailable, [], "sensitive record bulletin: RPMS did not record the acknowledged access")
      end

      def record_sensitive_acknowledgement(record)
        SensitiveRecordGateway.record_acknowledged_access(record)
      rescue ::RpmsRpc::NotConfiguredError
        raise
      rescue ::RpmsRpc::Error => e
        Rails.logger.error("[sensitive-record] bulletin raised #{e.class}")
        nil
      end

      def refuse_sensitive_record(outcome, messages, reason)
        note_audit_denial(reason)
        @sensitive_outcome = outcome
        @sensitive_messages = messages.map(&:to_s)
        render template: TEMPLATE, formats: :html, status: STATUS_BY_OUTCOME.fetch(outcome)
        false
      end
    end
  end
end
