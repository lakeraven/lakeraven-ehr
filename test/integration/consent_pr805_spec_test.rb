# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

# Specification tests for PR #805 / issue #793 gaps. Intentionally fail until
# handover tokens, kiosk re-lock listening, idle touch ordering, and audited
# session-end consistency are implemented.
class ConsentPr805SpecTest < ActionDispatch::IntegrationTest
  include ConsentWriteTestHelper

  setup do
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::AuditEvent.delete_all
    @demo_original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
    sign_in_clinician!(scopes: WRITE_SCOPES)
    open_patient_context!(DFN)
    install_consent_templates!
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
    Lakeraven::EHR::LoginThrottle.reset!
    teardown_oauth!
    Lakeraven::EHR::AuditEvent.delete_all
    Lakeraven::EHR::SignedConsent.delete_all if Lakeraven::EHR::SignedConsent.table_exists?
    Lakeraven::EHR::KioskLock.delete_all if Lakeraven::EHR::KioskLock.table_exists?
    Lakeraven::EHR::ConsentTemplate.delete_all if Lakeraven::EHR::ConsentTemplate.table_exists?
    Lakeraven::EHR.reset_configuration!
    restore_session_idle_expired_hook!
    if @demo_original_client
      RpmsRpc.configure { |c| c.client = @demo_original_client }
      @demo_original_client = nil
    end
  end

  test "kiosk signature form includes hidden handover_token for the rendered handover" do
    open_kiosk_via_handover!(template_key: TEMPLATE_BH)
    token = kiosk_lock_row.handover_token

    assert_select "form#consent-signature-form input[type=hidden][name=handover_token][value=?]", token
  end

  test "kiosk layout includes nonce BroadcastChannel listener that blanks on handover-ended and handover-started" do
    open_kiosk_via_handover!

    assert_kiosk_relock_listener_script!
  end

  test "POST kiosk signature without JavaScript still stores when handover_token matches current lock" do
    open_kiosk_via_handover!

    assert_select "form#consent-signature-form input[type=hidden][name=handover_token]", count: 1 do |inputs|
      token = inputs.first["value"]
      assert token.present?

      assert_difference -> { Lakeraven::EHR::SignedConsent.count }, +1 do
        post_kiosk_signature(handover_token: token)
      end
      assert_response :success
      assert_equal token, Lakeraven::EHR::SignedConsent.order(:id).last.handover_token
    end
  end

  test "POST kiosk signature without handover_token is refused and counts toward refusal cap" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    before = lock.refused_signature_count

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature
    end

    assert_includes [ 422, 429 ], response.status
    assert_equal before + 1, lock.reload.refused_signature_count
  end

  test "stale kiosk POST after staff unlock and new handover refuses stores nothing and counts refusal" do
    open_kiosk_via_handover!(template_key: TEMPLATE_BH)
    stale_token = kiosk_lock_row.handover_token
    bh_title = Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH).title
    assert_includes response.body, bh_title

    unlock_kiosk_returning_staff!
    post_handover(template_key: TEMPLATE_ROI)
    follow_redirect!

    lock = kiosk_lock_row
    refute_equal stale_token, lock.handover_token
    assert_equal TEMPLATE_ROI, lock.template_key
    roi_title = Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_ROI).title
    assert_includes response.body, roi_title

    refused_before = lock.refused_signature_count

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(handover_token: stale_token)
    end

    assert_includes [ 422, 429 ], response.status
    assert_equal refused_before + 1, lock.reload.refused_signature_count
  end

  test "matching handover_token on POST still signs current handover after template change" do
    open_kiosk_via_handover!(template_key: TEMPLATE_BH)
    unlock_kiosk_returning_staff!
    post_handover(template_key: TEMPLATE_ROI)
    follow_redirect!

    assert_select "form#consent-signature-form input[type=hidden][name=handover_token]", count: 1 do |inputs|
      current_token = inputs.first["value"]
      assert_equal kiosk_lock_row.handover_token, current_token

      assert_difference -> { Lakeraven::EHR::SignedConsent.count }, +1 do
        post_kiosk_signature(handover_token: current_token)
      end
      assert_response :success

      row = Lakeraven::EHR::SignedConsent.order(:id).last
      assert_equal TEMPLATE_ROI, row.template_key
      assert_equal current_token, row.handover_token
    end
  end

  test "staff consent list GET during handover does not refresh idle clock so kiosk expires at RPMS limit" do
    Lakeraven::EHR.configuration.session_idle_limit = 15.minutes
    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, rpms_idle_seconds: 600)
    open_patient_context!(DFN)
    signed_in_at = Time.current
    post_handover
    follow_redirect!

    touched_during_locked_list = false
    with_touch_session_spy(on: Lakeraven::EHR::ConsentsController, flag: -> { touched_during_locked_list = true }) do
      travel_to signed_in_at + 6.minutes do
        get BASE
        assert_redirected_to KIOSK
      end
    end
    refute touched_during_locked_list,
           "GET consent list during handover must not touch session before kiosk lock redirect"

    travel_to signed_in_at + 11.minutes do
      get KIOSK
    end

    assert_redirected_to "#{MOUNT}/login"
    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert event, "expected audit row when RPMS idle ends kiosk session"
    assert_match(/session timed out/i, event.outcome_desc.to_s)
  end

  test "ConsentsController registers kiosk lock redirect before require_authentication" do
    chain = Lakeraven::EHR::ConsentsController._process_action_callbacks
      .to_a
      .select { |callback| callback.kind == :before }
      .map(&:filter)
    lock_at = chain.index(:redirect_when_consent_kiosk_locked)
    auth_at = chain.index(:require_authentication)

    refute_nil lock_at, "expected kiosk lock redirect in ConsentsController before chain"
    refute_nil auth_at, "expected require_authentication in ConsentsController before chain"
    assert_operator lock_at, :<, auth_at,
                   "kiosk lock redirect must run before require_authentication touches the session"
  end

  test "AuditedSessionEnd does not serve kiosk after recording session timed out when super still accepts session" do
    open_kiosk_via_handover!
    Lakeraven::EHR::AuditEvent.delete_all

    with_session_idle_expired_sequence(true, false) do
      get KIOSK
    end

    refusal = Lakeraven::EHR::AuditEvent.order(:id).last
    if refusal && refusal.outcome_desc.to_s.match?(/session timed out|browser access refused/i)
      refute response.success?, "must not render kiosk 200 after audit recorded session end"
      assert_redirected_to "#{MOUNT}/login"
    else
      flunk "expected audited session timed out refusal when idle check disagrees"
    end
  end

  test "AuditedSessionEnd records session timed out when super ends session after idle check disagrees" do
    open_kiosk_via_handover!
    Lakeraven::EHR::AuditEvent.delete_all

    with_session_idle_expired_sequence(false, true) do
      get KIOSK
    end

    assert_redirected_to "#{MOUNT}/login"
    assert_equal 1, Lakeraven::EHR::AuditEvent.count, "expected one audit row when session ends on kiosk"
    assert_match(/session timed out/i, Lakeraven::EHR::AuditEvent.sole.outcome_desc.to_s)
    assert_equal DUZ, Lakeraven::EHR::AuditEvent.sole.agent_who_identifier
  end

  private

  def unlock_kiosk_returning_staff!
    with_authentication_stub(auth_success_result) do
      post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
    end
    follow_redirect!
  end

  def assert_kiosk_relock_listener_script!
    assert_select "script[data-consent-kiosk-listener]", count: 1 do |scripts|
      script = scripts.first
      assert script["nonce"].present?, "expected CSP nonce on kiosk re-lock script"
      text = script.text
      assert_includes text, CONSENT_KIOSK_BROADCAST_CHANNEL
      assert_includes text, "handover-started"
      assert_includes text, "handover-ended"
      assert_includes text, "textContent"
    end
  end

  def self.current_session_idle_answers
    Thread.current[:consent_pr805_idle_answers]
  end

  def self.current_session_idle_answers=(queue)
    Thread.current[:consent_pr805_idle_answers] = queue
  end

  def restore_session_idle_expired_hook!
    return unless @session_idle_expired_original

    Lakeraven::EHR::ConsentKioskController.define_method(
      :session_idle_expired?,
      @session_idle_expired_original
    )
    @session_idle_expired_original = nil
    self.class.current_session_idle_answers = nil
  end

  def with_touch_session_spy(on:, flag:)
    original = on.instance_method(:touch_session!)
    on.define_method(:touch_session!) do
      flag.call
      original.bind_call(self)
    end
    yield
  ensure
    on.define_method(:touch_session!, original)
  end

  def with_session_idle_expired_sequence(*answers)
    self.class.current_session_idle_answers = answers.dup
    controller = Lakeraven::EHR::ConsentKioskController
    @session_idle_expired_original ||= controller.instance_method(:session_idle_expired?)
    original = @session_idle_expired_original
    controller.define_method(:session_idle_expired?) do
      queue = ConsentPr805SpecTest.current_session_idle_answers
      return original.bind_call(self) if queue.nil? || queue.empty?

      queue.shift
    end
    yield
  ensure
    restore_session_idle_expired_hook!
  end
end
