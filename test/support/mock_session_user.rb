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
#
# CIAVCXUS HASKEYS is answered the same way: for the user the sign-on bound,
# one 0/1 per name asked, from the keys seed_held_keys gave that DUZ (HASKEY,
# CIAVCXUS.m:8-12, reads ^XUSEC(KEY,DUZ)). With nobody signed on it answers
# nothing, which held_keys reads as "could not ask".
#
# ORWU HAS OPTION ACCESS likewise answers for the user the sign-on bound: ["1"]
# for an option seed_options gave that DUZ, ["0"] for any other (the shape a
# real broker sends), and nothing with nobody signed on.
module MockSessionUser
  AV_CODE_RPC = "XUS AV CODE"
  HELD_KEYS_RPC = "CIAVCXUS HASKEYS"
  OPTION_ACCESS_RPC = "ORWU HAS OPTION ACCESS"

  def seed_user(duz, credentials:, name:, role:)
    super
    (@session_users ||= {})[duz.to_i] = { credentials: credentials, name: name, role: role }
  end

  # The SECURITY KEYs DUZ holds: what ^XUSEC(KEY,DUZ) would say.
  def seed_held_keys(duz, names)
    (@held_keys ||= {})[duz.to_i] = Array(names)
  end

  # The options DUZ may run: what ORWU HAS OPTION ACCESS would say.
  def seed_options(duz, names)
    (@options ||= {})[duz.to_i] = Array(names)
  end

  def seeded_reply(rpc_name, *params)
    reply = super
    bind_session_user(reply) if rpc_name == AV_CODE_RPC
    return held_keys_reply(params.first) if rpc_name == HELD_KEYS_RPC && reply == "" && @session_duz
    return option_access_reply(params.first) if rpc_name == OPTION_ACCESS_RPC && reply == "" && @session_duz

    reply
  end

  private

  def bind_session_user(reply)
    lines = Array(reply)
    duz = lines[0].to_i
    return unless duz.positive? && lines[1].to_s.strip == "0"

    @session_duz = duz
    user = @session_users&.dig(duz)
    seed_user(duz.to_s, **user) if user
  end

  def option_access_reply(name)
    [ Array(@options&.dig(@session_duz)).include?(name.to_s) ? "1" : "0" ]
  end

  def held_keys_reply(asked)
    held = @held_keys&.dig(@session_duz) || []
    [ asked.to_s.split("^", -1).map { |name| held.include?(name) ? "1" : "0" }.join("^") ]
  end
end

RpmsRpc::MockClient.prepend(MockSessionUser)
