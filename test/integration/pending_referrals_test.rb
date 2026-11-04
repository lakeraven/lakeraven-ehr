# frozen_string_literal: true

require "test_helper"

# #873: a user who works referrals sees the referrals pending at the facility,
# and the dashboard counts them, linked to that list. RPMS is stood in for at
# the wire: the mock broker answers BMC SEARCH REFERRAL with the reply a live
# rpms-ydb 7c3119b build gave the provider persona (BMCZMENU) on 2026-11-04,
# after test/integration/live_pending_referrals_test.rb filed an ACTIVE, an
# APPROVED and a CLOSED referral for a synthetic patient. RPMS's own status
# screen left the closed one out; the gem parses the rest as it would live.
class PendingReferralsTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  TODAY = Date.new(2026, 11, 4)

  # Both records arrive in one line: CRTMSG^BMCRPC4 files each in its own
  # node and the CIA broker sends them with nothing between (rpms-rpc#589).
  CAPTURED_PENDING =
    "~`1^NOV 01, 2026^^990003^CHARLIE,JORDAN^^^<UNKNOWN>^^ACTIVE^^^DIRECT ONLY^^^^^^^^^^06/03/1966^^" \
    "~`2^NOV 01, 2026^^990003^CHARLIE,JORDAN^^^<UNKNOWN>^^APPROVED^^^DIRECT ONLY^^^^^^^^^^06/03/1966^^"

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "206", user_type: "provider", user_name: "PROFILE,MD", security_keys: keys }
  end

  def answer(lines)
    RpmsRpc.client.seed_raw_lines(:referral_search, "", lines)
  end

  # The parameters of each BMC SEARCH REFERRAL RPMS was asked.
  def searches
    RpmsRpc.client.received_calls.select { |c| c[:rpc] == "BMC SEARCH REFERRAL" }.map { |c| c[:params] }
  end

  def visit(path, **params)
    travel_to(TODAY.to_time.change(hour: 9)) { get path, params: params }
  end

  def rows
    css_select("#pending-referrals tr[data-referral]").map do |tr|
      [ tr["data-referral"], tr.at_css("td[data-date]")["data-date"], tr["data-patient"], tr.at_css("td[data-status]")["data-status"] ]
    end
  end

  test "#873 a referral worker sees each pending referral with its date, patient and status, for the last 12 months" do
    answer([ CAPTURED_PENDING ])
    sign_in("referrals_user")
    visit "/lakeraven-ehr/referrals/pending"

    assert_response :ok
    assert_equal [ [ "", "", "NOV 04, 2025", "NOV 04, 2026", "", "Active/Approved" ] ], searches,
      "every patient (no patient, no provider), the last 12 months, RPMS's own open-status screen"
    assert_equal [ %w[1 2026-11-01 990003 active], %w[2 2026-11-01 990003 approved] ], rows
    assert_select "#pending-referrals caption", text: /2 referrals pending, initiated from Nov 4, 2025 to Nov 4, 2026/
    assert_select "#pending-referrals tr[data-referral='1'] th", text: /CHARLIE,JORDAN/
    assert_select "#pending-referrals tr[data-referral='2'] td[data-status='approved']", text: /Approved/
    assert_select "#pending-referrals tr[data-referral='1'] form[action='/lakeraven-ehr/patients/990003/context'][method='post'] button",
      text: /Open chart\s+for CHARLIE,JORDAN/
    assert_select "#from[value='2025-11-04']"
    assert_select "#to[value='2026-11-04']"
    assert_select "nav[aria-label='Main'] a[href='/lakeraven-ehr/referrals/pending']", text: "Referrals"
  end

  test "#873 the worker chooses other dates, and RPMS is asked for those" do
    answer([ CAPTURED_PENDING ])
    sign_in("referrals_supervisor")
    visit "/lakeraven-ehr/referrals/pending", from: "2026-11-01", to: "2026-11-02"

    assert_response :ok
    assert_equal [ [ "", "", "NOV 01, 2026", "NOV 02, 2026", "", "Active/Approved" ] ], searches
    assert_select "label[for='from']", text: "Initiated from"
    assert_select "#from[value='2026-11-01']"
  end

  test "#873 dates that are not dates, or the wrong way round, are refused and RPMS is not asked" do
    sign_in("referrals_user")
    [ { from: "2026-13-01", to: "2026-11-02" }, { from: "2026-11-02", to: "" }, { from: "2026-11-05", to: "2026-11-01" } ].each do |dates|
      visit "/lakeraven-ehr/referrals/pending", **dates

      assert_response :ok
      assert_select "#from_error", { minimum: 1 }, "#{dates}: the error is named next to the field"
      assert_select "#from[aria-invalid='true']"
      assert_select "#pending-referrals", count: 0
    end
    assert_empty searches
  end

  test "#873 no pending referrals is said so" do
    answer([])
    sign_in("referrals_user")
    visit "/lakeraven-ehr/referrals/pending"

    assert_select "#no-pending-referrals", text: /No referrals initiated from Nov 4, 2025 to Nov 4, 2026 are pending/
    assert_select "#pending-referrals", count: 0
  end

  test "#873 when RPMS does not answer, the list says so instead of showing none" do
    RpmsRpc.client.define_singleton_method(:call_rpc) { |*| raise RpmsRpc::Client::RpcError, "broker timeout" }
    sign_in("referrals_user")
    visit "/lakeraven-ehr/referrals/pending"

    assert_response :ok
    assert_select "#pending-referrals-unread", text: /could not be read from RPMS/
    assert_select "#no-pending-referrals", count: 0
    assert_select "#referral-window", { count: 1 }, "the dates can still be changed"
  end

  test "#873 a user who does not work referrals is refused the list, and RPMS is not asked" do
    sign_in("scheduling_user")
    visit "/lakeraven-ehr/referrals/pending"

    assert_response :forbidden
    assert_empty searches
  end

  test "#873 on a backend without prc_referrals there is no list" do
    sign_in("referrals_user")
    with_restricted_backend { visit "/lakeraven-ehr/referrals/pending" }

    assert_response :not_found
  end

  # The dashboard (#812's pattern): RPMS's count, a real zero included, linked
  # to where the work is done; a failed read is said so.

  test "#873 the dashboard counts the pending referrals of the list's default window, linked to the list" do
    answer([ CAPTURED_PENDING ])
    sign_in("referrals_user")
    visit "/lakeraven-ehr/dashboard"

    assert_response :ok
    assert_equal [ [ "", "", "NOV 04, 2025", "NOV 04, 2026", "", "Active/Approved" ] ], searches, "the list's own window"
    assert_select "#referral-counts td[data-count='2'] a[href='/lakeraven-ehr/referrals/pending']",
      text: /2\s+referrals pending, initiated in the last 12 months/
    assert_select "#referral-counts caption", text: /initiated from Nov 4, 2025 to Nov 4, 2026/
    assert_select "#no-counts", count: 0
  end

  test "#873 no pending referrals counts 0" do
    answer([])
    sign_in("referrals_user")
    visit "/lakeraven-ehr/dashboard"

    assert_select "#referral-counts td[data-count='0'] a", text: /0\s+referrals pending/
  end

  test "#873 when RPMS does not answer, the dashboard says so instead of showing zero" do
    RpmsRpc.client.define_singleton_method(:call_rpc) { |*| raise RpmsRpc::Client::RpcError, "broker timeout" }
    sign_in("referrals_user")
    visit "/lakeraven-ehr/dashboard"

    assert_response :ok
    assert_select "#referral-counts-unread", text: /could not be read from RPMS/
    assert_select "#referral-counts", count: 0
  end

  test "#873 a user who does not work referrals sees no count, and RPMS is not asked for one" do
    sign_in("")
    visit "/lakeraven-ehr/dashboard"

    assert_response :ok
    assert_empty searches
    assert_select "#referral-counts", count: 0
    assert_select "a[href='/lakeraven-ehr/referrals/pending']", count: 0
    assert_select "#no-counts"
  end

  test "#873 on a backend without prc_referrals a referral worker sees no count" do
    sign_in("referrals_user")
    with_restricted_backend { visit "/lakeraven-ehr/dashboard" }

    assert_response :ok
    assert_select "#referral-counts", count: 0
  end
end
