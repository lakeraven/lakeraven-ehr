# frozen_string_literal: true

require "test_helper"
require "securerandom"

# Live (rpms-ux S-REG-02): the front-desk persona registers patients on a real
# RPMS. It WRITES patients, so it runs only against a throwaway container and
# only when asked twice: LIVE_RPMS=1 (see test_helper.rb) and LIVE_RPMS_WRITES=1.
# Never point it at a shared stack.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9110 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_registration_register_patient_test.rb
class LiveRegistrationRegisterPatientTest < ActionDispatch::IntegrationTest
  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PREG123", password: "PREG123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  # A name and date of birth no one on the build has, so the first save files.
  def fresh_entry(dob: Date.new(1900 + rand(100), 1 + rand(12), 1 + rand(28)))
    letters = Array.new(6) { ("A".."Z").to_a.sample }.join
    { name: "LIVETEST,#{letters}", sex: "F", dob: dob.iso8601, ssn: "", tribe_ien: picked(:tribe), community_ien: picked(:community) }
  end

  def picked(kind)
    search = kind == :tribe ? { tribe_search: "A" } : { community_search: "WAPANUCKA" }
    get "/lakeraven-ehr/registration/patients/new", params: search
    assert_response :ok
    css_select("input[name='registration[#{kind}_ien]']").first["value"]
  end

  test "S-REG-02.1 a new patient is filed with a health record number, and the front desk finds them" do
    entry = fresh_entry
    post "/lakeraven-ehr/registration/patients", params: { registration: entry }

    assert_response :redirect
    dfn = response.location[%r{/registration/patients/(\d+)\z}, 1]
    follow_redirect!
    assert_select "#registered", text: /Health record number #{dfn}/

    get "/lakeraven-ehr/registration/patients", params: { q: entry[:name], dob: entry[:dob] }
    assert_select "#matches tr[data-dfn='#{dfn}'] td", text: dfn
  end

  test "S-REG-02.3 a patient already on file is shown before anything is filed" do
    post "/lakeraven-ehr/registration/patients",
         params: { registration: fresh_entry.merge(name: "MOUSE,MICKEY M", sex: "M", dob: "1910-02-14") }

    assert_response :conflict
    assert_select "#possible-matches tr[data-dfn='3'] td", text: "1001"
  end

  test "a different person born the same day is registered once the clerk has reviewed the match" do
    dob = Date.new(1950, 1 + rand(12), 1 + rand(28))
    post "/lakeraven-ehr/registration/patients", params: { registration: fresh_entry(dob: dob) }
    assert_response :redirect

    second = fresh_entry(dob: dob)
    post "/lakeraven-ehr/registration/patients", params: { registration: second }
    assert_response :conflict
    token = css_select("#confirm-different-person input[name='review_token']").first["value"]

    post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: token, registration: second }
    assert_response :redirect
    follow_redirect!
    assert_select "h1", text: second[:name]

    # A second confirm of the same review files nothing more.
    post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: token, registration: second }
    assert_response :conflict
    get "/lakeraven-ehr/registration/patients", params: { q: second[:name], dob: second[:dob] }
    assert_select "#matches tbody tr", count: 1
  end
end
