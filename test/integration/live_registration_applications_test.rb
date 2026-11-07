# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient_application"

# Live (rpms-ux S-REG-03.3 to 03.5): the front-desk persona records that a
# patient applied for Medicaid, then that it was approved, then marks it
# entered in error, on a real RPMS; FileMan is read back after each step. It
# WRITES (an application is never deleted), so it runs only against a throwaway
# container with PATIENT APPLICATION TYPES seeded (rpms-ops SEEDAPPT), and only
# when asked twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9151 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_applications_test.rb
class LiveRegistrationApplicationsTest < ActionDispatch::IntegrationTest
  DFN = 990_011 # a synthetic seed patient
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

  def applications
    LiveRpmsSession.sign_on!
    RpmsRpc::PatientApplication.for_patient(DFN)
  end

  # OVERALL STATUS OF APPLICATION (9000045.11 .04) for the application filed on +day+, read through FileMan.
  def fileman_status(app_ien)
    LiveRpmsSession.sign_on!
    header = RpmsRpc::DdrFileman.lister(file: "9000045", fields: "@;.01I", flags: "IP", xref: "B", from: (DFN - 1).to_s,
                                        max: 5)[:entries].find { |e| e[:pieces][0] == DFN.to_s }[:ien]
    reply = RpmsRpc::DdrFileman.gets_entry(file: "9000045.11", iens: "#{app_ien},#{header},", fields: ".01;.02;.04", flags: "I")
    reply[:fields].transform_values { |v| v[:internal] }
  end

  test "S-REG-03.3 to S-REG-03.5 an application is recorded, approved with a date, and marked entered in error" do
    taken = applications.map { |a| a[:obtained] }
    day = (1..365).map { |n| Date.current - n }.find { |d| !taken.include?(d) }
    medicaid = RpmsRpc::PatientApplication.types.find { |t| t[:name] == "MEDICAID FORM 100" }
    assert medicaid, "PATIENT APPLICATION TYPES has no MEDICAID FORM 100 (run rpms-ops SEEDAPPT)"

    sign_in
    post "#{BASE}/applications", params: { application: { type_ien: medicaid[:ien].to_s, applied_on: day.iso8601,
                                                          submitted_on: day.iso8601, submitted_via: "O" } }
    assert_redirected_to "#{BASE}/coverage#applications-section"
    app = applications.find { |a| a[:obtained] == day }
    assert app, "the application is not on file"
    assert_equal({ ".01" => RpmsRpc::FilemanDateParser.to_fileman(day), ".02" => medicaid[:ien].to_s, ".04" => "P" },
                 fileman_status(app[:ien]))

    sign_in
    get "#{BASE}/coverage"
    assert_select "#applications tr[data-application='#{app[:ien]}'] [data-status-badge]", text: "Pending"

    post "#{BASE}/applications/#{app[:ien]}/status", params: { status: "A", status_on: Date.current.iso8601 }
    assert_redirected_to "#{BASE}/coverage#applications-section"
    assert_equal "A", fileman_status(app[:ien])[".04"]
    assert_equal({ date: Date.current, status: "A" },
                 applications.find { |a| a[:ien] == app[:ien] }[:submissions].first[:statuses].last.slice(:date, :status))

    sign_in
    post "#{BASE}/applications/#{app[:ien]}/status", params: { status: "E", status_on: Date.current.iso8601 }
    assert_equal "E", fileman_status(app[:ien])[".04"]
    sign_in
    get "#{BASE}/coverage"
    assert_select "#applications tr[data-application='#{app[:ien]}'][data-status='E']"
  end
end
