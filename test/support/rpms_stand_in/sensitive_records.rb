# frozen_string_literal: true

module RpmsStandIn
  # The sensitive-record check the engine makes before it opens a record
  # (#613), answered where SensitiveRecordGateway asks rpms-rpc:
  # RpmsRpc::DgSensitive.check_access and .record_bulletin, by DFN.
  module SensitiveRecords
    # Each DFN's check answers 0, not sensitive. An unanswered check never
    # opens a record, so every record a test opens needs this.
    def not_sensitive(*dfns)
      dfns.flatten.each { |dfn| sensitive(dfn, result: 0) }
      self
    end

    # The check for DFN answers this code and RPMS's message lines. A nil
    # result is a check RPMS did not answer with a code.
    def sensitive(dfn, result:, messages: [])
      answers = state[:sensitive] ||= answering(:check_access)
      # A bulletin nobody stated an answer for is still asked for through the
      # stand-in, so it is on record: "no bulletin was sent" cannot pass on a
      # bulletin that went unseen. Unstated, RPMS did not answer it.
      state[:sensitive_bulletins] ||= answering(:record_bulletin)
      answers[dfn.to_s] = result.nil? ? nil : { result: result, messages: Array(messages) }
      self
    end

    # Whether RPMS logged the access to DFN's record and sent the bulletin.
    def sensitive_bulletin(dfn, success:)
      answers = state[:sensitive_bulletins] ||= answering(:record_bulletin)
      answers[dfn.to_s] = { success: success }
      self
    end

    private

    # Answers RpmsRpc::DgSensitive.method_name from a table by DFN, and
    # returns the table.
    def answering(method_name)
      {}.tap do |by_dfn|
        answer(RpmsRpc::DgSensitive, method_name) { |dfn: nil, **| by_dfn[dfn.to_s]&.dup }
      end
    end
  end

  extend SensitiveRecords
end
