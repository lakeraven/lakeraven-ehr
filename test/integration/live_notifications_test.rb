# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "rpms_rpc/cia_client"

# Live (#874, rpms-ux S-SGN-02.1): a notification addressed to the provider
# persona is listed with its patient, opening it puts that patient's chart in
# front of them, and the dashboard's count is the number RPMS holds for them.
#
# The notification is sent the way RPMS sends one: through Kernel's GUI alert
# API, XQAL GUI ALERTS with LOC=SEND (SETUP^XQALERT), the call the IHS EHR
# makes for its missing-POV alert (BEHOXQPC). It is an IHS EHR (BEHOXQ) alert
# for the demo patient MOUSE,MICKEY M, sent by the image's development
# operator, whom CIA lets call it (XUPROGMODE). It WRITES, so it runs only
# against a throwaway container and only when asked twice: LIVE_RPMS=1 (see
# test_helper.rb) and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9147 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_notifications_test.rb
class LiveNotificationsTest < ActionDispatch::IntegrationTest
  DFN = 3
  SENDER = %w[SYS123 RPMS.000].freeze # the image's development operator (README)

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  # One process holds one broker identity (rpms-rpc#234).
  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was unless @forgery_was.nil?
    LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
  end

  test "S-SGN-02.1 a notification sent to the provider is listed with its patient, opens the chart, and is counted" do
    sign_in_provider
    before = dashboard_count

    message = "Live notification #{SecureRandom.hex(4)}"
    send_alert(to: session[:duz], message: message)

    count = dashboard_count
    assert_equal before + 1, count, "the dashboard counts the notification just sent"
    assert_equal notifications_path, css_select("#notification-count a").first["href"]

    get notifications_path
    assert_response :ok
    rows = css_select("#notifications tbody tr")
    assert_equal count, rows.size, "the count is the number of notifications listed"
    row = rows.find { |tr| tr.at_css("td[data-message]").text.include?(message) }
    assert row, "the notification sent is listed"
    assert_equal DFN.to_s, row["data-dfn"]
    assert_match(/MOUSE,MICKEY M/, row.at_css("th[scope='row']").text, "listed with its patient")
    assert_match(/MANAGER,SYSTEM/, row.text, "from its sender")

    submit("#notifications tr[data-alert='#{row['data-alert']}'] form")
    assert_redirected_to "/lakeraven-ehr/patients/#{DFN}"
    follow_redirect!
    assert_response :ok
    assert_select "h1", text: /Mouse|MOUSE/
  end

  private

  def notifications_path = "/lakeraven-ehr/notifications"

  def submit(selector, params = {})
    form = Nokogiri::HTML(response.body).at_css(selector) or flunk("no form #{selector}")
    token = form.at_css("input[name='authenticity_token']")&.[]("value")
    post form["action"], params: params.merge(authenticity_token: token)
  end

  def sign_in_provider
    get "/lakeraven-ehr/login"
    submit("form[action$='/login']", username: "PMD123", password: "PMD123!!")
    assert_response :redirect, "signed on as the provider"
    follow_redirect!
  end

  def dashboard_count
    get "/lakeraven-ehr/dashboard"
    assert_response :ok
    cell = css_select("#notification-count").first
    assert cell, "the provider's dashboard counts notifications"
    cell["data-count"].to_i.tap { |n| assert_equal n.to_s, cell.at_css("a").text.split.first }
  end

  # Sends +to+ (a DUZ) an IHS EHR alert for DFN through XQAL GUI ALERTS, on a
  # connection of its own as the development operator.
  def send_alert(to:, message:)
    settings = Lakeraven::EHR::Engine.rpms_settings
    sender = RpmsRpc::CiaClient.new(host: settings[:host], port: Integer(settings[:port]), timeout: 30)
    sender.connect
    sender.authenticate(*SENDER)
    sender.call_rpc("XQAL GUI ALERTS", {
      "LOC" => "SEND",
      "XQA,#{to}" => "",
      "XQAID" => "BEHOXQ,LIVE874",
      "XQADATA" => "DFN=#{DFN}^PRI=2^INF=0",
      "XQAMSG" => message
    })
  ensure
    sender&.disconnect
  end
end
