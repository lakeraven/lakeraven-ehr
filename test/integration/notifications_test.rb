# frozen_string_literal: true

require "test_helper"
require_relative "../support/patient_banner_test_helper"

# rpms-ux S-SGN-02.1 and #874: a clinician sees their RPMS notifications, each
# with its patient and a way to open that patient's chart, and the dashboard
# counts them, linking to the list. RPMS is stood in for at the broker with
# the reply a rpms-ydb e9b78c8 container gave PROFILE,MD to BEHOXQ ALRLIST on
# 2026-11-04, after three alerts were sent to that user (two OE/RR alerts for
# the demo patient MOUSE,MICKEY M, one IHS EHR alert with no patient); the
# gem parses it as it parses the live reply. live_notifications_test.rb
# proves the same against the running build.
class NotificationsTest < ActionDispatch::IntegrationTest
  include PatientBannerTestHelper

  CAPTURED = [
    "1^0^^  ^Staff meeting moved to 3 PM.^3261104.175352^MANAGER,SYSTEM^0^BEHOXQ^BEHOXQ,PROBE;4;3261104.175352^0^PRI=1^INF=0",
    "2^1^MOUSE,MICKEY M    (1001)^  ^Unscheduled visit.^3261104.174742^POSTMASTER^3^OR.19^OR,3,19;.5;3261104.174742^1^",
    "2^1^MOUSE,MICKEY M    (1001)^  ^Unscheduled visit (probe).^3261104.175206^MANAGER,SYSTEM^3^OR.19^OR,3,19;4;3261104.175206^1^"
  ].freeze

  setup { seed_alerts(CAPTURED) }

  teardown do
    seed_alerts([])
    teardown_oauth!
  end

  def seed_alerts(lines) = RpmsRpc.client.seed_raw_lines(:notifications_inbox, "", lines)

  def rows = css_select("#notifications tbody tr").map { |tr| tr["data-alert"] }

  test "S-SGN-02.1 each notification is listed with its patient, and opens that patient's chart" do
    sign_in_clinician!
    get "#{MOUNT}/notifications"

    assert_response :ok
    assert_equal [ "BEHOXQ,PROBE;4;3261104.175352", "OR,3,19;4;3261104.175206", "OR,3,19;.5;3261104.174742" ], rows,
      "every alert RPMS holds for the user, newest first"
    visit = "#notifications tr[data-alert='OR,3,19;.5;3261104.174742']"
    assert_select "#{visit} th[scope='row']", text: /MOUSE,MICKEY M\s+HRN 1001/
    assert_select "#{visit} td[data-message]", text: /Unscheduled visit\.\s+For information\./
    assert_select "#{visit} td[data-priority='moderate']", text: "Moderate"
    assert_select "#{visit} time[datetime='2026-11-04T17:47']", text: "Nov 4, 2026 17:47"
    assert_select "#{visit} td", text: "POSTMASTER"
    assert_select "#{visit} form[action='#{MOUNT}/patients/3/context'][method='post'] button", text: /Open chart\s+for MOUSE,MICKEY M/
  end

  test "a notification with no patient says so and offers no chart" do
    sign_in_clinician!
    get "#{MOUNT}/notifications"

    meeting = "#notifications tr[data-alert='BEHOXQ,PROBE;4;3261104.175352']"
    assert_select "#{meeting} th", text: "No patient"
    assert_select "#{meeting} td[data-priority='high']"
    assert_select "#{meeting} form", count: 0
  end

  test "the dashboard counts the notifications RPMS holds for the user and links to them" do
    sign_in_clinician!
    get "#{MOUNT}/dashboard"

    assert_response :ok
    assert_select "#notification-count[data-count='3'] a[href='#{MOUNT}/notifications']", text: /3\s+notifications for you in RPMS/
    assert_select "nav[aria-label='Main'] a[href='#{MOUNT}/notifications']", text: "Notifications"
    assert_select "#no-counts", count: 0
  end

  test "a real zero is shown as zero, and the list says there are none" do
    seed_alerts([])
    sign_in_clinician!
    get "#{MOUNT}/dashboard"
    assert_select "#notification-count[data-count='0'] a", text: /0\s+notifications/

    get "#{MOUNT}/notifications"
    assert_response :ok
    assert_select "#no-notifications"
    assert_select "#notifications", count: 0
  end

  test "when RPMS refuses the read, the dashboard says so instead of a number, and the list does too" do
    restore = singleton_method_restore(RpmsRpc::Notifications, :inbox)
    RpmsRpc::Notifications.define_singleton_method(:inbox) { |**| raise RpmsRpc::Client::RpcError, "Access denied for remote procedure: BEHOXQ ALRLIST" }
    sign_in_clinician!

    get "#{MOUNT}/dashboard"
    assert_response :ok
    assert_select "#notification-count-unread[role='alert']", text: /could not be read from RPMS/
    assert_select "#notification-count", count: 0

    get "#{MOUNT}/notifications"
    assert_response :service_unavailable
    assert_select "#notifications", count: 0
    assert_select "#no-notifications", count: 0
  ensure
    restore&.call
  end

  test "a user who may not read the chart sees neither the count nor the list" do
    post "#{MOUNT}/test_session", params: { duz: "990", user_type: "user", user_name: "TEST,NOCHART", security_keys: [] }
    get "#{MOUNT}/dashboard"
    assert_select "#notification-count", count: 0
    assert_select "nav[aria-label='Main'] a[href='#{MOUNT}/notifications']", count: 0

    get "#{MOUNT}/notifications"
    assert_response :forbidden
    assert_no_match "MOUSE,MICKEY", response.body
  end
end
