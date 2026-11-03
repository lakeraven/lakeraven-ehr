# frozen_string_literal: true

require "test_helper"

# Live (rpms-ux S-REG-03): the registration persona records a patient's
# Medicaid on a real RPMS through the coverage screens, and FileMan confirms
# what AG filed. It WRITES coverage, so it runs only against a throwaway
# container and only when asked twice: LIVE_RPMS=1 (see test_helper.rb) and
# LIVE_RPMS_WRITES=1. Never point it at a shared stack.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9144 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_coverage_test.rb
class LiveRegistrationCoverageTest < ActionDispatch::IntegrationTest
  CURRENT_DFN = 990_050 # ASHGROVE,SAM on the pinned build
  LAPSED_DFN = 990_051  # ALPHA,AVERY: only ever given coverage that has ended

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PREG123", password: "PREG123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  def coverage_path(dfn) = "/lakeraven-ehr/registration/patients/#{dfn}/coverage"

  def fresh_number = "ZZ#{Array.new(7) { rand(10) }.join}"

  def washington
    post "#{coverage_path(CURRENT_DFN)}/new", params: { state_search: "WASHINGTON", coverage: { kind: "medicaid" } }
    assert_response :ok
    css_select("label[data-state] input[type='radio']").first["value"]
  end

  def fileman(file, iens, field, flags = "I")
    got = RpmsRpc.client.with_context("CIAV VUECENTRIC") do
      RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: field, flags: flags)
    end
    flunk "FileMan read #{file} #{iens} #{field}: #{got.inspect}" if got.nil? || got[:error]
    got.dig(:fields, field, flags == "I" ? :internal : :external).to_s
  end

  test "S-REG-03.1 a Medicaid number, state and eligibility dates are filed and show as in force today" do
    number = fresh_number
    year = Date.today.year
    state = washington

    post coverage_path(CURRENT_DFN), params: { coverage: { kind: "medicaid", number: number, state_ien: state,
                                                           starts_on: "#{year}-01-01", ends_on: "#{year + 1}-12-31" } }
    assert_redirected_to coverage_path(CURRENT_DFN)
    follow_redirect!
    assert_select "#coverage-saved", text: /Medicaid coverage saved/
    assert_select "#coverage tr[data-number='#{number}'][data-active='true'] [data-period]",
                  text: /Jan 1, #{year}\s+to\s+Dec 31, #{year + 1}/

    record = RpmsRpc::Coverage.on_file(CURRENT_DFN)[:medicaid].find { |c| c[:number] == number }
    refute_nil record, "AG does not read back Medicaid #{number}"
    iens = "#{record[:record_ien]},"
    assert_equal CURRENT_DFN.to_s, fileman("9000004", iens, ".01"), "#9000004 .01 is the patient"
    assert_equal number, fileman("9000004", iens, ".03"), "#9000004 .03 MEDICAID NUMBER"
    assert_equal state, fileman("9000004", iens, ".04"), "#9000004 .04 STATE"
    row = "#{record[:eligibility].first[:ien]},#{record[:record_ien]},"
    assert_equal "#{year - 1700}0101", fileman("9000004.11", row, ".01"), "ELIG. DATE"
    assert_equal "#{year + 1 - 1700}1231", fileman("9000004.11", row, ".02"), "ELIG. END DATE"
  end

  test "S-REG-03.2 Medicaid that ended reads not in force, and check-in would flag the patient" do
    number = fresh_number
    post coverage_path(LAPSED_DFN), params: { coverage: { kind: "medicaid", number: number, state_ien: washington,
                                                          starts_on: "2024-01-01", ends_on: "2025-06-30" } }
    assert_redirected_to coverage_path(LAPSED_DFN)
    follow_redirect!
    assert_select "#coverage tr[data-number='#{number}'][data-active='false'] td", text: "Not in force"

    assert_equal :lapsed, Lakeraven::EHR::CoverageGateway.standing(LAPSED_DFN)
  end
end
