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

      # DGMSG. The wrapper documents this parameter only by its signature
      # default, `generate_message: 0` (RpmsRpc::DgSensitive#check_access), and
      # docs/rpcs.md lists DGMSG as an optional parameter with no stated
      # meaning. Nothing citable says what a non-zero value makes PTSEC^DGSEC4
      # do, so the open sends the wrapper's documented default and reads only
      # what the wrapper documents: the code and RESULT(2+) message lines.
      GENERATE_MESSAGE = 0

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
