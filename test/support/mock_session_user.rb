# frozen_string_literal: true

require "rpms_rpc/mock_client"

# The session-user RPCs (ORWU USERINFO, XUS GET USER INFO) take no
# parameters: a real broker answers them for the user the sign-on bound.
# The gem's MockClient keeps one reply for every caller, and its seed_user
# overwrites that reply for each user it seeds, so without this the last
# user seeded would answer for whoever signs on. Sign-on reads the user
# class from ORWU USERINFO for the signed-on DUZ and refuses an answer for
# anyone else (rpms-rpc #236), so the mock has to bind it as a broker does.
#
# A successful XUS AV CODE reply re-seeds both replies for the DUZ it names,
# from that user's own seed_user arguments. Users seeded another way are
# left alone. Belongs in rpms-rpc's MockClient; kept here until it is.
module MockSessionUser
  AV_CODE_RPC = "XUS AV CODE"

  def seed_user(duz, credentials:, name:, role:)
    super
    (@session_users ||= {})[duz.to_i] = { credentials: credentials, name: name, role: role }
  end

  def seeded_reply(rpc_name, *params)
    reply = super
    bind_session_user(reply) if rpc_name == AV_CODE_RPC
    reply
  end

  private

  def bind_session_user(reply)
    lines = Array(reply)
    duz = lines[0].to_i
    return unless duz.positive? && lines[1].to_s.strip == "0"

    user = @session_users&.dig(duz)
    seed_user(duz.to_s, **user) if user
  end
end

RpmsRpc::MockClient.prepend(MockSessionUser)
