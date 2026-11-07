# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "rpms_rpc/cia_client"

# Live (rpms-ux S-SGN-02.2, 02.3 and 02.4; lakeraven/rpms-ux#78, pending
# merge): the provider removes a notification RPMS lists as deletable, sees no
# Remove on one it does not, and forwards one with a comment to the nurse,
# who sees it in their own list with the comment. Each persona is signed in
# through the real sign-in and works on their own RPMS connection (ADR 0011),
# with the page's CSRF token on every write.
#
# The notifications are sent the way RPMS sends one: Kernel's GUI alert API,
# XQAL GUI ALERTS with LOC=SEND (SETUP^XQALERT), on a connection of its own
# as the image's development operator, whom CIA lets call it (XUPROGMODE).
# XQACNDEL=1 is Kernel's "may be deleted without processing" flag, the CAN
# DELETE that BEHOXQ ALRLIST answers. What a test leaves behind is deleted
# for every recipient with LOC=DELETE. It WRITES, so it runs only against a
# throwaway container and only when asked twice:
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9181 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_notification_actions_test.rb
class LiveNotificationActionsTest < ActionDispatch::IntegrationTest
  DFN = 3 # MOUSE,MICKEY M, a demo patient of the image
  SENDER = %w[SYS123 RPMS.000].freeze # the image's development operator (README)
  PROVIDER = %w[PMD123 PMD123!!].freeze # PROFILE,MD
  NURSE = %w[PRN123 PRN123!!].freeze # PROFILE,RN
  MOUNT = "/lakeraven-ehr"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    @shared = RpmsRpc.configuration.client
    RpmsRpc.reset! # a pooled process holds no shared client
    settings = Lakeraven::EHR::Engine.rpms_settings
    Lakeraven::EHR::RpmsSessions.configure!(
      factory: -> { RpmsRpc.client_for(settings[:broker], host: settings[:host], port: settings[:port]) },
      max_sessions: 4, keeper: false
    )
    Lakeraven::EHR::LoginThrottle.reset!
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @sent = []
  end

  teardown do
    next unless defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"

    as_sender { |c| @sent.each { |id| c.call_rpc("XQAL GUI ALERTS", { "LOC" => "DELETE", "XQAID" => id }) } } if @sent.any?
    ActionController::Base.allow_forgery_protection = @forgery_was unless @forgery_was.nil?
    Lakeraven::EHR::RpmsSessions.reset!
    RpmsRpc.configure { |c| c.client = @shared }
  end

  test "S-SGN-02.2 and S-SGN-02.3 the provider removes a deletable notification, and one RPMS keeps offers no Remove" do
    provider = sign_in(*PROVIDER)
    removable = send_alert(provider, "Live removable #{SecureRandom.hex(3)}", removable: true)
    kept = send_alert(provider, "Live kept #{SecureRandom.hex(3)}")
    before = count(provider)

    provider.get "#{MOUNT}/notifications"
    provider.assert_response :ok
    assert_equal 1, form_count(provider, removable, "form[data-remove]"), "a deletable notification offers Remove"
    assert_equal 0, form_count(provider, kept, "form[data-remove]"), "S-SGN-02.3: one RPMS lists CAN DELETE 0 offers none"

    submit(provider, "#notifications tr[data-alert='#{removable}'] form[data-remove]")
    provider.assert_redirected_to "#{MOUNT}/notifications"
    provider.follow_redirect!
    assert_match(/Notification removed for MOUSE,MICKEY M\./, provider.css_select("#notification-done[role='status']").text)
    ids = row_ids(provider)
    refute_includes ids, removable, "S-SGN-02.2: the removed notification is no longer listed"
    assert_includes ids, kept
    assert_equal before - 1, count(provider), "S-SGN-02.2: the count is one fewer"

    event = Lakeraven::EHR::AuditEvent.where(action: "D").order(:id).last
    assert_equal [ "0", provider.session[:duz].to_s, "Patient", DFN.to_s ],
      [ event.outcome, event.agent_who_identifier, event.entity_type, event.entity_identifier ],
      "audited as a delete by the provider, naming the patient"
    puts "\n[live] #{removable} removed through the page; #{kept} offers no Remove"
  end

  test "S-SGN-02.4 the provider forwards a notification with a comment, and the nurse sees it with the comment" do
    provider = sign_in(*PROVIDER)
    nurse = sign_in(*NURSE)
    message = "Live forward #{SecureRandom.hex(3)}"
    alert_id = send_alert(provider, message)
    comment = "Please review today #{SecureRandom.hex(2)}"
    refute_includes row_ids(nurse), alert_id, "the nurse does not have it yet"

    provider.get "#{MOUNT}/notifications"
    provider.get provider.css_select("#notifications tr[data-alert='#{alert_id}'] a[data-forward]").first["href"]
    provider.assert_response :ok
    submit(provider, "#forward-search", "recipient_search" => "Profile,R")
    provider.assert_response :ok
    choice = provider.css_select("#forward-form label[data-recipient]").find { |l| l.text.strip.casecmp?("Profile,Rn") }
    assert choice, "the search lists the nurse"
    assert_equal nurse.session[:duz].to_s, choice["data-recipient"]

    submit(provider, "#forward-form", "forward[recipient_duz]" => choice["data-recipient"], "forward[comment]" => comment)
    provider.assert_redirected_to "#{MOUNT}/notifications"
    provider.follow_redirect!
    assert_equal "Notification forwarded to Profile,Rn.", provider.css_select("#notification-done[role='status']").text.strip
    assert_includes row_ids(provider), alert_id, "the provider keeps their own copy"

    nurse.get "#{MOUNT}/notifications"
    nurse.assert_response :ok
    row = nurse.css_select("#notifications tr[data-alert='#{alert_id}']").first
    assert row, "the forwarded notification is in the nurse's list"
    assert_includes row.at_css("td[data-message]").text, message
    assert_match(/MOUSE,MICKEY M/, row.at_css("th[scope='row']").text, "with its patient")
    assert_includes row.at_css("[data-alert-text]").text, comment, "with the provider's comment"

    event = Lakeraven::EHR::AuditEvent.where(action: "C", agent_who_identifier: provider.session[:duz].to_s).order(:id).last
    assert_equal [ "0", "Patient", DFN.to_s ], [ event.outcome, event.entity_type, event.entity_identifier ]
    puts "\n[live] #{alert_id} forwarded to DUZ #{nurse.session[:duz]} with its comment, shown in the nurse's list"
  end

  private

  def sign_in(access_code, verify_code)
    open_session do |s|
      s.get "#{MOUNT}/login"
      token = s.css_select("form[action$='/login'] input[name='authenticity_token']").first["value"]
      s.post "#{MOUNT}/login", params: { username: access_code, password: verify_code, authenticity_token: token }
      s.assert_redirected_to "#{MOUNT}/dashboard"
    end
  end

  def submit(s, selector, params = {})
    form = Nokogiri::HTML(s.response.body).at_css(selector) or flunk("no form #{selector}")
    fields = form.css("input[type='hidden']").to_h { |i| [ i["name"], i["value"] ] }
    method = fields.delete("_method") || form["method"]
    s.send(method.downcase.to_sym, form["action"], params: fields.merge(params))
  end

  def row_ids(s)
    s.get "#{MOUNT}/notifications"
    s.assert_response :ok
    s.css_select("#notifications tbody tr").map { |tr| tr["data-alert"] }
  end

  def form_count(s, alert_id, selector) = s.css_select("#notifications tr[data-alert='#{alert_id}'] #{selector}").size

  def count(s)
    s.get "#{MOUNT}/dashboard"
    s.css_select("#notification-count").first["data-count"].to_i
  end

  def sender_client
    @sender_client ||= begin
      settings = Lakeraven::EHR::Engine.rpms_settings
      c = RpmsRpc::CiaClient.new(host: settings[:host], port: Integer(settings[:port]), timeout: 30)
      c.connect
      c.authenticate(*SENDER)
      c
    end
  end

  def as_sender
    yield sender_client
  ensure
    @sender_client&.disconnect
    @sender_client = nil
  end

  # Sends +to+'s user an IEHR alert for DFN and answers its ID as listed in
  # that user's notifications (Kernel completes it as XQAID;sender;time).
  def send_alert(to, message, removable: false)
    xqaid = "BEHOXQ,LIVE#{SecureRandom.hex(3).upcase}"
    data = { "LOC" => "SEND", "XQAID" => xqaid, "XQADATA" => "DFN=#{DFN}^PRI=2^INF=0",
             "XQAMSG" => message, "XQA,#{to.session[:duz]}" => "" }
    data["XQACNDEL"] = "1" if removable
    as_sender { |c| c.call_rpc("XQAL GUI ALERTS", data) }
    id = row_ids(to).find { |row| row.start_with?("#{xqaid};") }
    assert id, "the alert just sent is listed for #{to.session[:duz]}"
    @sent << id
    id
  end
end
