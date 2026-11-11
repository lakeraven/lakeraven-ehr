# frozen_string_literal: true

require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/referral"

# Seeds the mock broker for the outside-app follow-up prototype (#988-#990):
# a synthetic patient's open RCIS referral, the reads
# RpmsRpc::Referral.record_follow_up makes before BMC UPDATE REFERRAL, the
# routine's reply, and what follow_up_state reads back afterwards. The mock
# is not stateful, so the read-back is seeded with what a test expects RPMS
# to hold; the test also checks that BMC UPDATE REFERRAL was sent exactly
# that. These are seeded replies, not live RPMS (rpms-rpc#722 has the live spec).
module RcisFollowUpMock
  FLAGS = RpmsRpc::Referral::INCLUDE_FLAG_FIELDS.sort

  def seed_open_referral(dfn:, ien:, purpose: "CARDIOLOGY CONSULT")
    RpmsRpc.client.seed_keyed_collection(:referral_search, dfn.to_s, [
      { ien: ien.to_s, patient_dfn: dfn.to_i, status: "ACTIVE", date: Date.new(2026, 11, 1),
        purpose: purpose, facility: "<UNKNOWN>" }
    ])
    pre = [ "90001^#{ien},^.15^A", "90001^#{ien},^1302^14", "90001^#{ien},^1303^" ] +
          FLAGS.map { |f| "90001^#{ien},^#{f}^N" }
    RpmsRpc.client.seed(:ddr_gets_entry_data, gets_key(ien, ".15;1302;1303;#{FLAGS.join(';')}"), "[Data]\n#{pre.join("\n")}")
    RpmsRpc.client.seed(:ddr_lister, RpmsRpc::DdrFileman.lister_param(file: "90001.22", iens: ",#{ien},",
                                                                      fields: "@;.01", flags: "IP").to_s, "[Data]")
  end

  def seed_update_reply(ien:, reply: "~`1")
    RpmsRpc.client.seed_scalar(:bmc_update_referral, ien.to_s, reply)
  end

  def seed_read_back(ien:, appointment:, note_ien: "41", note_text:)
    RpmsRpc.client.seed(:ddr_gets_entry_data, gets_key(ien, ".15;1106"),
                        "[Data]\n90001^#{ien},^.15^A\n90001^#{ien},^1106^#{appointment}")
    notes_key = RpmsRpc::DdrFileman.lister_param(file: "90001.03", fields: "@;.01;.03;.05", flags: "IP",
                                                 screen: "I $P(^(0),U,3)=#{ien},$P(^(0),U,5)=\"C\"").to_s
    RpmsRpc.client.seed(:ddr_lister, notes_key, "[Data]\n#{note_ien}^3261111^#{ien}^C")
    RpmsRpc.client.seed(:ddr_gets_entry_data, RpmsRpc::DdrFileman.gets_entry_param(
      file: "90001.03", iens: "#{note_ien},", fields: "1", flags: "I").to_s,
      "[Data]\n90001.03^#{note_ien},^1^[WORD PROCESSING]\n#{note_text}\n$$END$$")
  end

  def bmc_update_calls
    RpmsRpc.client.received_calls.select { |c| c[:rpc] == "BMC UPDATE REFERRAL" }.map { |c| c[:params].to_a }
  end

  private

  def gets_key(ien, fields)
    RpmsRpc::DdrFileman.gets_entry_param(file: "90001", iens: "#{ien},", fields: fields, flags: "I").to_s
  end
end
