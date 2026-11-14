# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/tribal"

# Live (lakeraven-ehr#982): a registration manager adds a name-change and a
# legal-sex eligibility modifier to the site's table on a real RPMS, and
# FileMan is read back; a clerk without the manager key is refused the page.
# It WRITES, so it runs only against a throwaway container and only when asked
# twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1. The persona holds AGZMGR
# (PROFILE,REGSUP on the demo build); LIVE_RPMS_CLERK_* is one without it
# (PROFILE,REG).
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9100 \
#   LIVE_RPMS_ACCESS=PRSUP123 LIVE_RPMS_VERIFY='PRSUP123!!' \
#   LIVE_RPMS_CLERK_ACCESS=PREG123 LIVE_RPMS_CLERK_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_setup_modifiers_test.rb
class LiveRegistrationSetupModifiersTest < ActionDispatch::IntegrationTest
  BASE = "/lakeraven-ehr/registration/setup/eligibility_modifiers"
  DFN = 990_013 # a synthetic seed patient, for the eligibility check

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  def sign_in(access, verify)
    post "/lakeraven-ehr/login", params: { username: access, password: verify }
  end

  def sign_in_as_manager = sign_in(ENV.fetch("LIVE_RPMS_ACCESS"), ENV.fetch("LIVE_RPMS_VERIFY"))

  # The #9000030 entry as FileMan holds it: [.01, .02].
  def fileman(ien)
    reply = RpmsRpc.client.with_context("CIAV VUECENTRIC") do
      RpmsRpc::DdrFileman.gets_entry(file: "9000030", iens: "#{ien},", fields: ".01;.02", flags: "I")
    end
    [ reply[:fields].dig(".01", :internal), reply[:fields].dig(".02", :internal) ]
  end

  def added_ien(name)
    get BASE
    row = css_select("#eligibility-modifier-table tr[data-modifier]").find { |tr| tr.at_css("td").text.strip == name }
    assert row, "#{name} is listed"
    row["data-modifier"].to_i
  end

  test "#982 a name-change modifier is added, read back from RPMS, listed and renamed" do
    sign_in_as_manager
    name = "LIVE PROOF OF NAME #{Time.now.strftime('%H%M%S')}"

    post BASE, params: { name: name.downcase, type: "N" }
    assert_response :redirect, flash[:alert].to_s
    ien = added_ien(name)
    assert_equal [ name, "N" ], fileman(ien), "filed upper case with type N"
    assert_select "tr[data-modifier='#{ien}'] td", text: "Name change"

    post "#{BASE}/#{ien}", params: { name: "#{name} X" }
    assert_response :redirect, flash[:alert].to_s
    assert_equal [ "#{name} X", "N" ], fileman(ien), "renamed; the type stays"
  end

  test "#982 adding a legal-sex modifier leaves a patient's eligibility status as it was" do
    sign_in_as_manager
    before = RpmsRpc::Tribal.enrollment(DFN)&.dig(:eligibility_status)
    name = "LIVE PROOF OF SEX #{Time.now.strftime('%H%M%S')}"

    post BASE, params: { name: name, type: "S" }
    assert_response :redirect, flash[:alert].to_s
    assert_equal [ name, "S" ], fileman(added_ien(name))
    assert_equal before, RpmsRpc::Tribal.enrollment(DFN)&.dig(:eligibility_status)
  end

  test "#982 an eligibility-status reason is listed with no edit control, and its edit is refused" do
    sign_in_as_manager
    get BASE
    reason = css_select("#eligibility-modifier-table tr[data-modifier]").find { |tr| tr.css("td")[1].text.strip == "C" }
    assert reason, "the demo table has a type C reason"
    assert_empty reason.css("a"), "no edit control on an eligibility-status reason"

    ien = reason["data-modifier"].to_i
    before = fileman(ien)
    post "#{BASE}/#{ien}", params: { name: "NOT CHANGED HERE" }
    assert_response :unprocessable_content
    assert_equal before, fileman(ien)
  end

  test "#982 a clerk without the manager key finds no add control and is refused the page" do
    sign_in(ENV.fetch("LIVE_RPMS_CLERK_ACCESS"), ENV.fetch("LIVE_RPMS_CLERK_VERIFY"))
    get "/lakeraven-ehr/registration/patients"
    assert_response :success
    assert_select "a", text: "Setup", count: 0

    get BASE
    assert_response :forbidden
    assert_select "#add-eligibility-modifier", count: 0
    post BASE, params: { name: "LIVE REFUSED", type: "N" }
    assert_response :forbidden
  end
end
