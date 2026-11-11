# frozen_string_literal: true

module Lakeraven
  module EHR
    # Demo prototype (#990; not in the December build). Writes a CONFIRMED
    # outside-app follow-up to the RPMS referral, then reads the referral back
    # from RPMS, and records both on the follow-up.
    #
    # - Only a confirmed follow-up is written; a pending or rejected one never is.
    # - Idempotent: one already written is not written again, so a retry never
    #   files a second case note.
    # - A failed write is kept on the follow-up with RPMS's reason, for the
    #   review page to show and offer a retry.
    #
    # The write is RpmsRpc::Referral.record_follow_up (BMC UPDATE REFERRAL),
    # which rpms-rpc#722 has not yet run live. Corvid is not written here.
    class ReferralFollowUpWriteBack
      Result = Struct.new(:success, :detail, :read_back, keyword_init: true)

      def self.call(follow_up, gateway: ServiceRequestGateway)
        new(follow_up, gateway).call
      end

      def initialize(follow_up, gateway)
        @follow_up = follow_up
        @gateway = gateway
      end

      def call
        raise ArgumentError, "only a confirmed follow-up is written to RPMS" unless @follow_up.confirmed?
        return Result.new(success: true, detail: "already written", read_back: @follow_up.read_back) if @follow_up.written_back?

        written = @gateway.record_follow_up(@follow_up.referral_ien, appointment_on: @follow_up.appointment_on,
                                            case_note: @follow_up.case_note)
        return failed(written[:message].presence || written[:error].to_s.presence || "RPMS did not file it") unless written[:success]

        state = @gateway.follow_up_state(@follow_up.referral_ien)
        read_back = state && read_back_of(state)
        @follow_up.update!(write_back_status: "written", write_back_detail: "Filed on RPMS referral #{@follow_up.referral_ien}",
                           read_back: read_back)
        AppFollowUpAudit.record!(@follow_up, action: "E", what: "written to RPMS referral", duz: @follow_up.reviewed_by_duz)
        Result.new(success: true, detail: @follow_up.write_back_detail, read_back: read_back)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        failed("RPMS could not be reached (#{e.class.name.demodulize})")
      end

      private

      def failed(reason)
        @follow_up.update!(write_back_status: "failed", write_back_detail: reason.to_s.truncate(250))
        AppFollowUpAudit.record!(@follow_up, action: "E", what: "write to RPMS referral failed", outcome: "8",
                                             duz: @follow_up.reviewed_by_duz)
        Result.new(success: false, detail: @follow_up.write_back_detail)
      end

      # What RPMS answered, as the review page shows it: the status code, the
      # date of service as a date, and the newest case note's text.
      def read_back_of(state)
        {
          "status" => state[:status],
          "appointment" => state[:appointment],
          "appointment_on" => fileman_date(state[:appointment])&.iso8601,
          "case_note" => Array(state[:case_notes]).last&.dig(:text)
        }
      end

      def fileman_date(value)
        digits = value.to_s[/\A(\d{3})(\d{2})(\d{2})/] && Regexp.last_match
        digits && Date.new(digits[1].to_i + 1700, digits[2].to_i, digits[3].to_i)
      rescue Date::Error
        nil
      end
    end
  end
end
