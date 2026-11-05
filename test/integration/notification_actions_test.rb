# frozen_string_literal: true

require "test_helper"
require_relative "../support/patient_banner_test_helper"

# rpms-ux S-SGN-02.2, 02.3 and 02.4 (lakeraven/rpms-ux#78, pending merge):
# a clinician removes a notification RPMS lists as one they can delete, sees
# no Remove on one it does not, and forwards one to a colleague found by name,
# with a comment that shows in the colleague's list.
#
# RPMS is stood in for at the broker with the replies a rpms-ydb e9b78c8
# container gave on 2026-11-04 (live_notification_actions_test.rb runs the
# same against the build): BEHOXQ ALRLIST for PROFILE,MD (DUZ 206) after two
# IHS EHR alerts were sent to them, one with Kernel's may-delete flag
# (XQACNDEL=1, CAN DELETE 1) and one without; BEHOXQ ALRPP's answer (the
# handler's IEN, 3); BEHOXQ FORWARD's (0); BEHOXQ ALRMSG for the nurse
# PROFILE,RN after the forward (the comment); and ORWU NEWPERS for "PROFILE".
class NotificationActionsTest < ActionDispatch::IntegrationTest
  include PatientBannerTestHelper

  CLINICIAN = "206" # PROFILE,MD
  REMOVABLE = "BEHOXQ,CAP28D0R;4;3261104.210134"
  KEPT = "BEHOXQ,CAP28D0K;4;3261104.210134"
  CAPTURED = [
    "2^0^MOUSE,MICKEY M    (1001)^  ^Capture removable 28D0^3261104.210134^MANAGER,SYSTEM^3^BEHOXQ^#{REMOVABLE}^1^DFN=3^PRI=2^INF=0",
    "2^0^MOUSE,MICKEY M    (1001)^  ^Capture kept 28D0^3261104.210134^MANAGER,SYSTEM^3^BEHOXQ^#{KEPT}^0^DFN=3^PRI=2^INF=0"
  ].freeze
  NEWPERS_PROFILE = [
    "204^Profile,Ma^- MEDICAL ASSISTANT",
    "206^Profile,Md^- PHYSICIAN",
    "207^Profile,Reg^- PAT REG.",
    "205^Profile,Rn^- NURSE",
    "208^Profile,Sched^- MEDICAL SCHEDULER",
    "200^Provider,Test"
  ].freeze
  COMMENT = "Please review today 28D0"

  setup do
    Lakeraven::EHR::AuditEvent.delete_all
    RpmsRpc.client.received_calls.clear
    @lines = CAPTURED.dup
    seed_alerts
    RpmsRpc.client.seed_raw_lines(:user_management_user_list, "PROFILE", NEWPERS_PROFILE)
    RpmsRpc.client.seed_scalar(:notifications_forward, KEPT, 0)
    RpmsRpc.client.seed_text(:notifications_message, KEPT, COMMENT)
    @restore_rpc = rpms_removes_on_alrpp!
  end

  teardown do
    @restore_rpc&.call
    RpmsRpc.client.seed_raw_lines(:notifications_inbox, "", [])
    RpmsRpc.client.seed_raw_lines(:user_management_user_list, "PROFILE", [])
    restore_forgery_protection!
    teardown_oauth!
  end

  def seed_alerts = RpmsRpc.client.seed_raw_lines(:notifications_inbox, "", @lines)

  # BEHOXQ ALRPP answers its handler's IEN (3, as the container did) and, on
  # RPMS, the alert leaves the user's list: the next ALRLIST does not carry it.
  def rpms_removes_on_alrpp!
    RpmsRpc.client.seed_scalar(:notifications_remove, REMOVABLE, 3)
    client = RpmsRpc.client
    test = self
    original = client.method(:call_rpc)
    client.define_singleton_method(:call_rpc) do |rpc_name, *params|
      reply = original.call(rpc_name, *params)
      test.drop_alert(params.first.to_s) if rpc_name == "BEHOXQ ALRPP" && reply.to_s.to_i.positive?
      reply
    end
    -> { client.singleton_class.send(:remove_method, :call_rpc) }
  end

  def drop_alert(alert_id)
    @lines = @lines.reject { |line| line.split("^")[9] == alert_id }
    seed_alerts
  end

  def sent(rpc) = RpmsRpc.client.received_calls.select { |c| c[:rpc] == rpc }
  def rows = css_select("#notifications tbody tr").map { |tr| tr["data-alert"] }
  def row(id) = "#notifications tr[data-alert='#{id}']"
  def last_audit = Lakeraven::EHR::AuditEvent.order(:id).last

  def sign_in!
    enable_forgery_protection!
    sign_in_clinician!(duz: CLINICIAN)
  end

  # The form on the page, submitted with its own CSRF token and hidden fields.
  def submit(selector, params = {})
    form = Nokogiri::HTML(response.body).at_css(selector) or flunk("no form #{selector}")
    fields = form.css("input[type='hidden']").to_h { |i| [ i["name"], i["value"] ] }
    method = fields.delete("_method") || form["method"]
    send(method.downcase.to_sym, form["action"], params: fields.merge(params))
  end

  def dashboard_count
    get "#{MOUNT}/dashboard"
    css_select("#notification-count").first["data-count"].to_i
  end

  test "S-SGN-02.2 a notification RPMS lists as deletable is removed: gone from the list, and the count is one fewer" do
    sign_in!
    before = dashboard_count
    get "#{MOUNT}/notifications"
    assert_select "#{row(REMOVABLE)} form[data-remove='#{REMOVABLE}'][method='post'] input[name='_method'][value='delete']", 1
    assert_select "#{row(REMOVABLE)} form[data-remove] button", text: /Remove\s+Capture removable 28D0/

    submit("#{row(REMOVABLE)} form[data-remove]")
    assert_redirected_to "#{MOUNT}/notifications"
    assert_equal [ [ REMOVABLE ] ], sent("BEHOXQ ALRPP").map { |c| c[:params].to_a }, "ALRPP sent once, with the alert ID"
    follow_redirect!
    assert_select "#notification-done[role='status']", text: "Notification removed for MOUSE,MICKEY M."
    assert_equal [ KEPT ], rows, "the removed notification is no longer listed"
    assert_equal before - 1, dashboard_count, "the count is one fewer"
  end

  test "S-SGN-02.2 the removal is audited as a delete, by the signed-on user, naming the notification's patient" do
    sign_in!
    get "#{MOUNT}/notifications"
    submit("#{row(REMOVABLE)} form[data-remove]")

    event = Lakeraven::EHR::AuditEvent.where(action: "D").last
    refute_nil event, "the removal left an audit row"
    assert_equal [ "0", "Practitioner", CLINICIAN, "Patient", "3" ],
      [ event.outcome, event.agent_who_type, event.agent_who_identifier, event.entity_type, event.entity_identifier ]
  end

  test "S-SGN-02.3 a notification RPMS lists as not deletable offers no Remove, and a removal sent anyway is refused and it stays" do
    sign_in!
    get "#{MOUNT}/notifications"
    assert_select "#{row(KEPT)} form[data-remove]", 0
    assert_select "#{row(KEPT)} a[data-forward='#{KEPT}']", 1, "it can still be forwarded"

    delete "#{MOUNT}/notifications/#{KEPT}", params: { authenticity_token: css_select("meta[name='csrf-token']").first["content"] }
    assert_redirected_to "#{MOUNT}/notifications"
    assert_empty sent("BEHOXQ ALRPP"), "the gem refuses before RPMS is asked: CAN DELETE is 0"
    follow_redirect!
    assert_select "#notification-alert[role='alert']", text: /RPMS did not remove this notification/
    assert_includes rows, KEPT
  end

  test "a notification no longer in the list is not sent to RPMS" do
    sign_in!
    get "#{MOUNT}/notifications"
    delete "#{MOUNT}/notifications/BEHOXQ,GONE;4;3261104.210134", params: { authenticity_token: css_select("meta[name='csrf-token']").first["content"] }
    assert_redirected_to "#{MOUNT}/notifications"
    follow_redirect!
    assert_select "#notification-alert[role='alert']", text: "That notification is no longer in your list."
    assert_empty sent("BEHOXQ ALRPP")
  end

  test "a removal without the page's CSRF token is refused and nothing is sent" do
    sign_in!
    delete "#{MOUNT}/notifications/#{REMOVABLE}"
    assert_response :unprocessable_content
    assert_empty sent("BEHOXQ ALRPP")
    assert_equal "4", last_audit.outcome, "recorded as a refusal"
  end

  test "when RPMS fails part way through a removal, the user is told it is not confirmed" do
    RpmsRpc.client.define_singleton_method(:call_rpc) do |rpc_name, *params|
      raise RpmsRpc::Client::RpcError, "connection reset" if rpc_name == "BEHOXQ ALRPP"

      super(rpc_name, *params)
    end
    sign_in!
    get "#{MOUNT}/notifications"
    submit("#{row(REMOVABLE)} form[data-remove]")
    follow_redirect!
    assert_select "#notification-alert[role='alert']", text: /RPMS did not confirm the removal/
  end

  test "S-SGN-02.4 a notification is forwarded to a colleague chosen by name, with a comment, and the user keeps it" do
    sign_in!
    get "#{MOUNT}/notifications"
    get css_select("#{row(KEPT)} a[data-forward]").first["href"]
    assert_response :ok
    assert_select "#forward-notification[data-alert='#{KEPT}']", text: /Capture kept 28D0\s+About MOUSE,MICKEY M\./
    assert_select "#forward-form textarea[name='forward[comment]'][maxlength='245']"

    submit("#forward-search", "recipient_search" => "Profile")
    assert_response :ok
    assert_equal %w[204 207 205 208], css_select("#forward-form label[data-recipient]").map { |l| l["data-recipient"] },
      "users whose names start with the text, without the user themself or a name past it"
    assert_select "#forward-form label[data-recipient='205']", text: /Profile,Rn/

    submit("#forward-form", "recipient_search" => "Profile", "forward[recipient_duz]" => "205", "forward[comment]" => COMMENT)
    assert_redirected_to "#{MOUNT}/notifications"
    call = sent("BEHOXQ FORWARD").sole
    assert_equal [ KEPT, { "1" => "205" }, COMMENT ], call[:params].to_a
    follow_redirect!
    assert_select "#notification-done[role='status']", text: "Notification forwarded to Profile,Rn."
    assert_includes rows, KEPT, "forwarding leaves the user's own copy"

    event = Lakeraven::EHR::AuditEvent.where(action: "C").last
    assert_equal [ "0", CLINICIAN, "Patient", "3" ], [ event.outcome, event.agent_who_identifier, event.entity_type, event.entity_identifier ]
  end

  test "S-SGN-02.4 the comment a notification was forwarded with shows on its row" do
    sign_in!
    get "#{MOUNT}/notifications"
    assert_select "#{row(KEPT)} td[data-message] [data-alert-text]", text: /#{COMMENT}/
    assert_select "#{row(REMOVABLE)} [data-alert-text]", 0, "no comment or long text: nothing more shown"
  end

  test "a DUZ the search does not list is not forwarded to" do
    sign_in!
    get "#{MOUNT}/notifications/#{KEPT}/forward"
    submit("#forward-form", "recipient_search" => "Profile", "forward[recipient_duz]" => "4")
    assert_response :unprocessable_content
    assert_select "#forward-errors[role='alert']", text: /Colleague is not one the search lists/

    submit("#forward-form", "recipient_search" => "", "forward[recipient_duz]" => "205")
    assert_response :unprocessable_content, "a choice with no search behind it is refused too"
    assert_empty sent("BEHOXQ FORWARD")
  end

  test "a forward with no colleague, a comment too long, or a caret in it is not sent" do
    sign_in!
    get "#{MOUNT}/notifications/#{KEPT}/forward"
    submit("#forward-search", "recipient_search" => "Profile")
    assert_select "#forward-errors", 0

    submit("#forward-form", "recipient_search" => "Profile", "forward[comment]" => "Hello")
    assert_select "#forward-errors li", text: /Colleague is needed/

    submit("#forward-form", "recipient_search" => "Profile", "forward[recipient_duz]" => "205", "forward[comment]" => "x" * 246)
    assert_select "#forward-errors li", text: "Comment is at most 245 characters"

    submit("#forward-form", "recipient_search" => "Profile", "forward[recipient_duz]" => "205", "forward[comment]" => "see ^ here")
    assert_select "#forward-errors li", text: "Comment cannot contain the ^ character"
    assert_select "#forward-form textarea", { text: "see ^ here" }, "what was typed is kept"
    assert_empty sent("BEHOXQ FORWARD")
  end

  test "a user who may not read the chart can neither remove nor forward" do
    post "#{MOUNT}/test_session", params: { duz: "990", user_type: "user", user_name: "TEST,NOCHART", security_keys: [] }
    delete "#{MOUNT}/notifications/#{REMOVABLE}"
    assert_response :forbidden
    get "#{MOUNT}/notifications/#{KEPT}/forward"
    assert_response :forbidden
    post "#{MOUNT}/notifications/#{KEPT}/forward", params: { recipient_search: "Profile", forward: { recipient_duz: "205" } }
    assert_response :forbidden
    assert_empty sent("BEHOXQ ALRPP")
    assert_empty sent("BEHOXQ FORWARD")
  end
end
