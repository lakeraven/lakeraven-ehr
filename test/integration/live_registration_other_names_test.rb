# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"

# Live (rpms-ux S-REG-12): the front-desk persona records the other names a
# patient has used on a real RPMS, and FileMan is
# read back to prove each landed. It WRITES, so it runs only against a throwaway
# container and only when asked twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9143 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_other_names_test.rb
class LiveRegistrationOtherNamesTest < ActionDispatch::IntegrationTest
  DFN = 990_009 # INDIA,QUINN, a synthetic seed patient
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  # FileMan's internal values, read over DDR GETS ENTRY DATA as the run's persona.
  def fileman(file, iens, fields)
    LiveRpmsSession.sign_on!
    reply = RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: fields, flags: "I")
    assert reply && !reply[:error], "no #{file} entry #{iens}"
    reply[:fields].transform_values { |value| value[:internal] }
  end

  test "S-REG-12.2 and S-REG-12.4 an other name is added, found by search, and removed" do
    name = "LIVEALIAS#{Array.new(4) { ('A'..'Z').to_a.sample }.join},QUINN"
    post "#{BASE}/other_names", params: { other_name: { name: name } }
    assert_redirected_to "#{BASE}/other_names"

    post "/lakeraven-ehr/registration/patients/search", params: { q: name.split(",").first }
    assert_select "#matches tr[data-dfn='#{DFN}']"

    get "#{BASE}/other_names"
    ien = css_select("#other-names tr").find { |row| row.text.include?(name) }&.[]("data-other-name")
    assert ien, "the added name is not listed"
    assert_equal name, fileman("2.01", "#{ien},#{DFN},", ".01")[".01"]

    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
    post "#{BASE}/other_names/#{ien}/remove"
    assert_redirected_to "#{BASE}/other_names"
    LiveRpmsSession.sign_on!
    refute_includes RpmsRpc::PatientProfile.aliases(DFN).map { |row| row[:name] }, name
  end
end
