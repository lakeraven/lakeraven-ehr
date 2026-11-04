# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"

# Live (#873): a user who works referrals sees the facility's pending
# referrals, and the dashboard counts them, on a real RPMS. Referrals are
# filed through the stock FileMan filer (DDR FILER), as rpms-rpc's
# test/live/referral_pending_live_test.rb files them: BMC ADD REFERRAL takes
# 40 positional parameters a fixture cannot fill honestly. Each run files an
# ACTIVE, an APPROVED and a CLOSED referral initiated in a window no other
# spec files in (March 2004), and the same three a few days ago, inside the
# list's default window. The list must show exactly the open ones of the
# first window, and the dashboard's count must be the default list's length,
# the open ones of this run in it and the closed one not.
#
# It WRITES (a referral is never deleted), so it runs only against a throwaway
# container and only when asked twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
# The persona is the provider, who holds RCIS's menu key BMCZMENU.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9148 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_pending_referrals_test.rb
class LivePendingReferralsTest < ActionDispatch::IntegrationTest
  REFERRAL_FILE = "90001"
  OLD_WINDOW = (Date.new(2004, 3, 1)..Date.new(2004, 3, 31))
  OPEN = %w[A A1].freeze # ACTIVE, APPROVED
  CLOSED = "C1"          # CLOSED-COMPLETED
  FIXTURE_DFN = 990_003  # a synthetic seed patient

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    @today = Date.today
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "#873 the referral worker's list is exactly the open referrals initiated in the dates chosen, the closed one left out" do
    old = ensure_filed(OLD_WINDOW.begin + 9)
    sign_in

    get "/lakeraven-ehr/referrals/pending", params: { from: OLD_WINDOW.begin.iso8601, to: OLD_WINDOW.end.iso8601 }

    assert_response :ok
    assert_equal old.values_at(*OPEN).sort, listed.keys.sort, "exactly the ACTIVE and APPROVED referrals initiated in March 2004"
    OPEN.each do |status|
      row = listed.fetch(old[status])
      assert_equal (OLD_WINDOW.begin + 9).iso8601, row[:date]
      assert_equal FIXTURE_DFN.to_s, row[:patient]
      assert_equal({ "A" => "active", "A1" => "approved" }.fetch(status), row[:status])
      assert row[:name].present?, "the patient is named"
      assert_select "#pending-referrals tr[data-referral='#{old[status]}'] form[action='/lakeraven-ehr/patients/#{FIXTURE_DFN}/context'] button",
        text: /Open chart\s+for\s+#{Regexp.escape(row[:name])}/
    end
    assert_select "#pending-referrals caption", text: /2 referrals pending, initiated from Mar 1, 2004 to Mar 31, 2004/
  end

  test "#873 the dashboard counts the default list, linked to it, and the closed referral is not counted" do
    recent = ensure_filed(@today - 3)
    sign_in

    get "/lakeraven-ehr/dashboard"
    assert_response :ok
    cell = css_select("#referral-counts td[data-count]").first
    assert cell, "the dashboard counts pending referrals for a user who works them"
    count = cell["data-count"].to_i
    link = cell.at_css("a")
    assert_equal count.to_s, link.text.split.first
    assert_equal "/lakeraven-ehr/referrals/pending", link["href"]

    get link["href"]
    assert_response :ok
    assert_equal count, listed.size, "the count is the default list's length"
    assert_equal (@today << 12).iso8601, css_select("#from").first["value"], "the default window is the last 12 months"
    assert_equal @today.iso8601, css_select("#to").first["value"]
    OPEN.each { |status| assert listed.key?(recent[status]), "the #{status} referral filed #{@today - 3} is listed" }
    assert_not listed.key?(recent[CLOSED]), "the closed referral is not"
  end

  test "#873 a user who does not work referrals sees no count, and the list refuses them" do
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
    assert_response :redirect, "signed on as the scheduler"

    get "/lakeraven-ehr/dashboard"
    assert_response :ok
    assert_select "#referral-counts", count: 0
    assert_select "a[href='/lakeraven-ehr/referrals/pending']", count: 0

    get "/lakeraven-ehr/referrals/pending"
    assert_response :forbidden
  end

  private

  def sign_in
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
    assert_response :redirect, "signed on as the referral worker"
  end

  # { ien => { date:, patient:, status:, name: } } for the list's rows.
  def listed
    css_select("#pending-referrals tr[data-referral]").to_h do |tr|
      [ tr["data-referral"], { date: tr.at_css("td[data-date]")["data-date"], patient: tr["data-patient"],
                               status: tr.at_css("td[data-status]")["data-status"],
                               name: tr.at_css("th").children.first.text.strip } ]
    end
  end

  # { status => ien }: an ACTIVE, an APPROVED and a CLOSED referral for the
  # fixture patient initiated on date, filing the ones not already on file.
  def ensure_filed(date)
    on_file = referrals_on_file
    (OPEN + [ CLOSED ]).to_h do |status|
      [ status, on_file[[ fm(date), FIXTURE_DFN.to_s, status ]] || file_referral(date, status) ]
    end
  end

  # { [date, dfn, status] => ien } for every referral, internal values.
  def referrals_on_file
    listed = RpmsRpc::DdrFileman.lister(file: REFERRAL_FILE, fields: "@;.01;.03;.15", flags: "IP", max: "*")
    flunk "DDR LISTER on file #{REFERRAL_FILE} gave no reply" if listed.nil?
    flunk "DDR LISTER on file #{REFERRAL_FILE} answered an error" if listed[:error]

    listed[:entries].to_h { |e| [ e[:pieces].first(3), e[:ien] ] }
  end

  # DATE INITIATED, PATIENT, IN-HOUSE (no), OUTPATIENT and STATUS OF REFERRAL.
  def file_referral(date, status)
    values = { ".01" => fm(date), ".03" => FIXTURE_DFN.to_s, ".04" => "N", ".14" => "O", ".15" => status }
    rows = values.map { |field, value| { file: REFERRAL_FILE, field: field, iens: "+1,", value: value } }
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
    assert filed && filed[:success], "DDR FILER could not file a #{status} referral on #{date}: #{filed.inspect}"
    filed[:iens].fetch(1)
  end

  def fm(date)
    format("%<y>03d%<m>02d%<d>02d", y: date.year - 1700, m: date.month, d: date.day)
  end
end
