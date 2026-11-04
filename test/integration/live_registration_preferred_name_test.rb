# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"

# Live (rpms-ux S-REG-12.1): the front-desk persona records the name a patient
# goes by on a real RPMS, FileMan is read back to prove it landed, and the
# patient search finds the patient by it. It WRITES, so it runs only against a
# throwaway container and only when asked twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9151 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_preferred_name_test.rb
class LiveRegistrationPreferredNameTest < ActionDispatch::IntegrationTest
  DFN = 990_009 # INDIA,QUINN, a synthetic seed patient
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    sign_in
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  def sign_in
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  # PREFERRED NAME, IHS PATIENT (9000001) 9001, read over DDR GETS ENTRY DATA as the run's persona.
  def stored_preferred_name
    LiveRpmsSession.sign_on!
    reply = RpmsRpc::DdrFileman.gets_entry(file: "9000001", iens: "#{DFN},", fields: "9001", flags: "I")
    assert reply && !reply[:error], "no 9000001 entry #{DFN}"
    reply[:fields].dig("9001", :internal)
  end

  test "S-REG-12.1 a preferred name is saved, read back, shown, found by search, and cleared" do
    name = "Q#{Array.new(5) { ('A'..'Z').to_a.sample }.join}"
    post "#{BASE}/preferred_name", params: { preferred_name: { name: name.downcase } }
    assert_redirected_to "#{BASE}#preferred-name-section"
    assert_equal name, stored_preferred_name

    sign_in
    get BASE
    assert_select "#registration [data-field='preferred_name']", text: name

    post "/lakeraven-ehr/registration/patients/search", params: { q: "INDIA,#{name}" }
    assert_select "#matches tr[data-dfn='#{DFN}']"

    post "#{BASE}/preferred_name", params: { preferred_name: { name: "" } }
    assert_redirected_to "#{BASE}#preferred-name-section"
    assert_equal "", stored_preferred_name
  end
end
