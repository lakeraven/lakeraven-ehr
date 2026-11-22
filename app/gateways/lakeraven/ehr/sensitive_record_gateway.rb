# frozen_string_literal: true

require "rpms_rpc/api/dg_sensitive"

module Lakeraven
  module EHR
    # DG SECURITY's sensitive-record check on opening a record (#613), through
    # RpmsRpc::DgSensitive:
    #
    #   check   DG SENSITIVE RECORD ACCESS (PTSEC^DGSEC4): may this user open
    #           the record, and on what terms. Writes a DG SECURITY LOG entry.
    #   record  DG SENSITIVE RECORD BULLETIN (NOTICE^DGSEC4): the user has
    #           acknowledged the warning; write the log entry and send the
    #           bulletin.
    #
    # Both run on whatever RpmsRpc.client is, so on the signed-in user's own
    # connection inside RpmsUserScope: RPMS decides for, and logs against, the
    # user opening the record. The gem's answers are returned as they come:
    # nil is "RPMS did not answer", never "not sensitive", and the caller
    # decides what each answer means.
    class SensitiveRecordGateway
      # The option the open runs under. The wrapper scopes OR CPRS GUI CHART
      # for both calls (RpmsRpc::DgSensitive::CONTEXT), so DGOPT names it too.
      OPTION = "OR CPRS GUI CHART"

      # NOTICE^DGSEC4 ACTION 3, the routine's own default (dg_sensitive.rb,
      # record_bulletin: "ACTION defaults to 3 in the routine"): write the
      # DG SECURITY LOG entry and send the bulletin.
      LOG_AND_SEND = 3

      # DGMSG: ask PTSEC^DGSEC4 for its message lines. The only captured
      # sensitive reply, rpms-rpc test/fixtures/captured_replies/
      # dg-sensitive.yml capture `sensitive/1` (inputs 990028, 1,
      # OR CPRS GUI CHART), was taken with DGMSG=1 and carried the warning
      # lines in RESULT(2+); the not-sensitive captures, sent with 0, carry a
      # code and no lines. The warning page shows RPMS's own text, so the open
      # asks the way that capture did, not with the wrapper's signature
      # default of 0.
      #
      # Still owed: live proof under the app's own call (this option, the
      # signed-in user's connection) that PTSEC^DGSEC4 returns those lines.
      # The page refuses correctly either way: the code alone decides the
      # open, and a warning or denial with no lines is still refused.
      GENERATE_MESSAGE = 1

      class << self
        # { result: Integer, messages: [String] }, or nil when RPMS did not
        # answer. A DFN that is not a positive integer is the gem's own -1 and
        # sends nothing. Raises the gem's error when the call fails.
        def check(dfn, via: ::RpmsRpc::DgSensitive)
          via.check_access(dfn: dfn, generate_message: GENERATE_MESSAGE, option: OPTION)
        end

        # { success: true | false }, or nil when RPMS did not answer. Raises
        # the gem's error when the call fails.
        def record_acknowledged_access(dfn, via: ::RpmsRpc::DgSensitive)
          via.record_bulletin(dfn: dfn, action: LOG_AND_SEND, option: OPTION)
        end
      end
    end
  end
end
