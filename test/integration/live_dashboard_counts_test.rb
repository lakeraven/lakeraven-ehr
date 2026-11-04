# frozen_string_literal: true

require "test_helper"

# Live (#812, rpms-ux S-SCH-05.1, S-SCH-05.3): the dashboard's counts are
# RPMS's. The scheduler persona books into a clinic today and cancels one of
# the bookings through the app, on a real RPMS, and the dashboard's count for
# that clinic is the clinic day's own list read back: every appointment but
# the cancelled ones and the no-shows. It WRITES, so it runs only against a
# throwaway container and only when asked twice: LIVE_RPMS=1 (see
# test_helper.rb) and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9145 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_dashboard_counts_test.rb
class LiveDashboardCountsTest < ActionDispatch::IntegrationTest
  CLINIC = "DEMO IHS CLINIC"
  PATIENT = 3

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    @today = Date.today
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-05.1 and 05.3 each of the scheduler's clinics shows today's appointments from RPMS, linked to the clinic's day" do
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
    assert_response :redirect, "signed on as the scheduler"
    resources = RpmsRpc::Scheduling.resources.select { |r| r[:view] }
    clinic = resources.find { |r| r[:name] == CLINIC }
    day = "/lakeraven-ehr/scheduling/clinics/#{clinic[:id]}"
    before = dashboard_count(clinic)

    kept = book_today(day)
    cancelled = book_today(day)
    cancel(day, cancelled)

    get "/lakeraven-ehr/dashboard"
    assert_response :ok
    assert_equal resources.map { |r| r[:id].to_s }.sort, css_select("#clinic-counts tr[data-resource]").map { |tr| tr["data-resource"] }.sort,
      "S-SCH-05.1: a row for exactly the clinics BSDX names the scheduler on"
    count = dashboard_count(clinic)
    assert_equal before + 1, count, "the booking counts, the cancelled one does not"

    link = css_select("#clinic-counts tr[data-resource='#{clinic[:id]}'] a").first
    assert_equal "#{day}?date=#{@today.iso8601}", link["href"]
    get link["href"]
    assert_response :ok
    statuses = css_select("#appointments td[data-status]").map { |td| td["data-status"] }
    assert_equal count, statuses.count { |s| !%w[cancelled no-show].include?(s) },
      "S-SCH-05.3: the count is the clinic day's appointments, less the cancelled and no-shows"
    assert_select "#appointments tr[data-appointment='#{kept}'] td[data-status='booked']"
    assert_select "#appointments tr[data-appointment='#{cancelled}'] td[data-status='cancelled']"
  end

  test "a user who does not schedule sees no clinic count, and none of the old made-up ones" do
    post "/lakeraven-ehr/login", params: { username: "PMD123", password: "PMD123!!" }
    assert_response :redirect, "signed on as the provider"
    get "/lakeraven-ehr/dashboard"
    assert_response :ok
    assert_select "#clinic-counts", count: 0
    assert_select "#notification-count", 1, "the provider's notifications are counted (#874, live_notifications_test.rb)"
    %w[Active\ Cases My\ Tasks Pending\ Referrals].each { |label| assert_not_includes response.body, label }
  end

  private

  def dashboard_count(clinic)
    get "/lakeraven-ehr/dashboard"
    assert_response :ok
    cell = css_select("#clinic-counts tr[data-resource='#{clinic[:id]}'] td[data-count]").first
    assert cell, "a row for #{clinic[:name]}"
    cell["data-count"].to_i.tap { |n| assert_equal n.to_s, cell.at_css("a").text.split.first }
  end

  # Books MOUSE into an open time today through the app; the appointment id.
  def book_today(day)
    get day, params: { date: @today.iso8601 }
    open = css_select("#open-times tr[data-time]").select { |tr| tr.at_css("td[data-open]")["data-open"].to_i.positive? }
    before = css_select("#appointments tr[data-appointment]").map { |tr| tr["data-appointment"] }
    open.shuffle.each do |tr|
      post "#{day}/appointments", params: { booking: { patient_dfn: PATIENT.to_s, start: "#{@today.iso8601}T#{tr['data-time']}", length: "15", note: "" } }
      next unless response.redirect?

      follow_redirect!
      added = css_select("#appointments tr[data-appointment]").map { |row| row["data-appointment"] } - before
      return added.first if added.one?
    end
    skip "no open time left today on the throwaway container"
  end

  def cancel(day, id)
    path = "#{day}/appointments/#{id}/cancel"
    get path, params: { date: @today.iso8601, whom: "C" }
    reason = css_select("#cancellation-form select option").find { |o| o["value"].present? }["value"]
    post path, params: { date: @today.iso8601, cancellation: { whom: "C", reason_ien: reason, remarks: "live dashboard count" } }
    assert_response :redirect, "cancelled #{id}"
  end
end
