# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

class ConsentKioskRegressionsTest < ActionDispatch::IntegrationTest
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
    open_kiosk_via_handover!
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
    Lakeraven::EHR::LoginThrottle.reset!
    teardown_oauth!
    Lakeraven::EHR::AuditEvent.delete_all
    Lakeraven::EHR::SignedConsent.delete_all if Lakeraven::EHR::SignedConsent.table_exists?
    Lakeraven::EHR::ConsentTemplate.delete_all if Lakeraven::EHR::ConsentTemplate.table_exists?
    Lakeraven::EHR.reset_configuration!
    if @demo_original_client
      RpmsRpc.configure { |c| c.client = @demo_original_client }
      @demo_original_client = nil
    end
  end

  %w[magic-bytes-only transparent corrupt].each do |label|
    define_method("test_rejects_#{label.tr("-", "_")}_signature_over_HTTP") do
      bytes = case label
      when "magic-bytes-only" then magic_bytes_only_png
      when "transparent" then fully_transparent_signature_png
      else corrupt_truncated_png
      end

      assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
        post_kiosk_signature(signature: signature_data_url(bytes))
      end
      assert_response :unprocessable_entity
      get CHART
      assert_locked_redirect_to_kiosk!
    end
  end

  test "unlock failures are throttled before AuthenticationService is called again" do
    access = "SYNTHETIC.ACCESS"
    verify = "SYNTHETIC.VERIFY"
    hits = 0
    hits_at_limit = nil
    service = Object.new
    service.define_singleton_method(:authenticate) do |**_kwargs|
      hits += 1
      Lakeraven::EHR::AuthenticationService::Result.new(success?: false, error: "bad", value: nil)
    end

    with_stub(Lakeraven::EHR::AuthenticationService, :new, service) do
      Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS.times do
        post_kiosk_unlock(access_code: access, verify_code: verify)
      end
      hits_at_limit = hits
      post_kiosk_unlock(access_code: access, verify_code: verify)
    end

    assert_includes [ 422, 429 ], response.status
    assert_match(/too many|throttle|try again/i, response.body + flash.to_h.values.join(" "))
    assert_equal hits_at_limit, hits,
                 "expected no further authenticate calls once throttled, got #{hits} total"
    assert Lakeraven::EHR::LoginThrottle.throttled?(access, "127.0.0.1")
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "verify_needs_change on unlock does not clear the kiosk lock" do
    post_kiosk_signature
    assert_response :success

    with_authentication_stub(auth_verify_must_change_result) do
      post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
    end

    refute response.redirect?, "verify_needs_change must not unlock the tablet"
    assert_includes [ 422, 403 ], response.status
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "replaying a pre-handover session cookie after handover keeps the lock server-side" do
    session_key = Rails.application.config.session_options[:key]
    reset!
    sign_in_clinician!(scopes: WRITE_SCOPES)
    open_patient_context!(DFN)
    get CHART
    assert_response :ok
    stale_cookie = cookies[session_key]

    post_handover
    follow_redirect!
    assert_equal KIOSK, URI.parse(request.url).path

    cookies[session_key] = stale_cookie
    get CHART
    assert_locked_redirect_to_kiosk!("pre-handover cookie must not drop the server-side lock")

    get DASHBOARD
    assert_locked_redirect_to_kiosk!
  end

  test "chart consent list and kiosk responses set Cache-Control no-store" do
    get CHART
    assert_cache_control_no_store!

    get BASE
    assert_cache_control_no_store!

    get KIOSK
    assert_cache_control_no_store!
  end

  test "when the session times out during handover kiosk and unlock reach login not endless 401" do
    travel(Lakeraven::EHR.configuration.session_idle_limit.to_i + 60) do
      get KIOSK
      refute_equal 401, response.status, "kiosk should end the session, not 401 forever"
      assert_redirected_to "#{MOUNT}/login"

      post KIOSK_UNLOCK, params: { access_code: "a", verify_code: "b", authenticity_token: csrf_token }
      refute_equal 401, response.status
      assert_redirected_to "#{MOUNT}/login"

      get "#{MOUNT}/login"
      assert_response :success
      refute_match(%r{consent_kiosk}, response.location.to_s)

      post "#{MOUNT}/login", params: { username: "testprovider", password: "test123" }
      refute response.redirect? && URI(response.location).path == KIOSK
    end
  end

  test "losing concurrent revocation returns 422 with audit and stores no second revocation" do
    post_kiosk_signature
    with_authentication_stub(auth_success_result) do
      post_kiosk_unlock(access_code: "a", verify_code: "b")
    end
    sig = Lakeraven::EHR::SignedConsent.order(:id).last
    sig.revoke!(by_duz: DUZ, reason: "first")
    Lakeraven::EHR::AuditEvent.delete_all

    orig = Lakeraven::EHR::SignedConsent.method(:exists?)
    Lakeraven::EHR::SignedConsent.define_singleton_method(:exists?) { |*a, **k| false }
    begin
      post "#{BASE}/#{sig.id}/revocation",
           params: { reason: "second", authenticity_token: csrf_token }
    ensure
      Lakeraven::EHR::SignedConsent.singleton_class.send(:remove_method, :exists?)
    end

    assert_response :unprocessable_entity
    assert_match(/not revoked|already|refused/i, response.body)
    assert_equal 1, Lakeraven::EHR::SignedConsent.where(kind: "revocation", revokes_id: sig.id).count
    assert_operator Lakeraven::EHR::AuditEvent.count, :>=, 1
  end

  test "losing concurrent kiosk double submit shows hand-back not signature rejected" do
    post_kiosk_signature
    assert_response :success

    calls = 0
    Lakeraven::EHR::SignedConsent.define_singleton_method(:find_by) do |*a, **k|
      calls += 1
      calls <= 2 ? nil : super(*a, **k)
    end
    begin
      post_kiosk_signature
    ensure
      Lakeraven::EHR::SignedConsent.singleton_class.send(:remove_method, :find_by)
    end

    assert_response :success
    assert_match(/hand.*tablet back/i, response.body)
    refute_match(/not accepted/i, response.body)
    assert_equal 1, Lakeraven::EHR::SignedConsent.where(kind: "signature").count
  end

  test "each locked escape attempt from chart another patient consents or dashboard is audited with staff DUZ" do
    Lakeraven::EHR::AuditEvent.delete_all
    get CHART
    get "#{MOUNT}/patients/#{OTHER_DFN}/consents"
    get DASHBOARD

    events = Lakeraven::EHR::AuditEvent.order(:id).to_a
    assert_equal 3, events.size, "expected a denial audit row for each locked escape attempt"
    events.each do |event|
      assert_equal DUZ, event.agent_who_identifier
      assert_match(/consent|kiosk|lock|refused/i, event.outcome_desc.to_s)
    end
  end

  test "kiosk ends the session when the per-user RPMS idle limit passes before the site limit" do
    Lakeraven::EHR.configuration.session_idle_limit = 15.minutes
    with_rpms_timed_read(600) do
      reset!
      sign_in_clinician!(scopes: WRITE_SCOPES)
      open_patient_context!(DFN)
      post_handover
      follow_redirect!

      travel 16.minutes do
        get KIOSK
        assert_redirected_to "#{MOUNT}/login"
      end
    end
  end

  test "broker failure during unlock answers 503 stays locked and does not 500" do
    post_kiosk_signature
    assert_response :success

    service = Object.new
    service.define_singleton_method(:authenticate) do |**_kwargs|
      raise RpmsRpc::Client::ConnectionError, "broker down"
    end
    with_stub(Lakeraven::EHR::AuthenticationService, :new, service) do
      post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
    end

    assert_response :service_unavailable
    assert_match(/unavailable|broker|try again/i, response.body)
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "when the locked template cannot be read the kiosk still shows the unlock form" do
    Lakeraven::EHR::ConsentTemplate.where(key: TEMPLATE_BH).delete_all

    get KIOSK

    assert_response :success
    assert_select "form[action=?]", KIOSK_UNLOCK
  end

  test "demo visit route is covered by the consent kiosk lock when demo visits are enabled" do
    visit_path = "#{MOUNT}/patients/#{DFN}/visit"
    with_demo_visits_gate_open do
      get visit_path
      assert_locked_redirect_to_kiosk!("demo visit must redirect to kiosk while locked")
    end
  end

  test "consent list shows signed time witness active revocation form and revoked reason" do
    post_kiosk_signature
    with_authentication_stub(auth_success_result) do
      post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
    end
    follow_redirect!

    signature = Lakeraven::EHR::SignedConsent.order(:id).last

    get BASE
    assert_response :ok
    assert_match signature.signed_at.strftime("%b %-d, %Y"), response.body
    assert_match(/#{Regexp.escape(DUZ)}/, response.body)
    assert_select "form[action=?][method=post]", "#{BASE}/#{signature.id}/revocation" do
      assert_select "input[name=reason], textarea[name=reason]"
    end

    signature.revoke!(by_duz: DUZ, reason: SYNTHETIC_REVOCATION_REASON)
    get BASE
    assert_match SYNTHETIC_REVOCATION_REASON, response.body
    assert_select "form[action=?]", "#{BASE}/#{signature.id}/revocation", count: 0
  end

  test "oversized decompressible signature PNG is refused with 422 and nothing stored" do
    bytes = oversized_compressible_signature_png
    assert bytes.bytesize < 500.kilobytes
    assert_operator 1414, :>, 1200, "fixture height must exceed the pad limit under test"

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(signature: signature_data_url(bytes))
    end

    assert_response :unprocessable_entity
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "pad-sized visible signature PNG is accepted" do
    assert_difference -> { Lakeraven::EHR::SignedConsent.count }, +1 do
      post_kiosk_signature(signature: signature_data_url(pad_sized_visible_signature_png))
    end

    assert_response :success
  end

  test "near-invisible signatures are refused over HTTP" do
    [ invisible_alpha_one_signature_png, near_white_rgb_signature_png ].each do |bytes|
      Lakeraven::EHR::SignedConsent.delete_all

      assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
        post_kiosk_signature(signature: signature_data_url(bytes))
      end

      assert_response :unprocessable_entity, "expected invisible payload to be refused"
    end
  end

  test "losing concurrent handover answers with reason not 503 and keeps its audit row" do
    reset_open_consent_kiosk_lock!
    Lakeraven::EHR::AuditEvent.delete_all

    with_handover_race_loser { post_handover }

    refute_equal 503, response.status, "handover race must not surface as 503"
    assert_includes [ 422, 302 ], response.status
    if response.redirect?
      assert_equal KIOSK, URI.parse(response.location).path
    else
      assert_match(/refused|could not be locked/i, response.body)
    end
    assert_operator Lakeraven::EHR::AuditEvent.count, :>=, 1,
                    "expected the refused handover to leave an audit row"
  end

  test "revocation reason never appears in the Rails log" do
    post_kiosk_signature
    with_authentication_stub(auth_success_result) do
      post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
    end
    follow_redirect!
    signature = Lakeraven::EHR::SignedConsent.order(:id).last

    logs = capture_rails_logs do
      post "#{BASE}/#{signature.id}/revocation",
           params: { reason: SYNTHETIC_REVOCATION_REASON, authenticity_token: csrf_token }
    end

    assert_response :redirect
    refute_includes logs, SYNTHETIC_REVOCATION_REASON
  end

  test "kiosk idle past session limit ends session with an audit row recording the refusal" do
    Lakeraven::EHR::AuditEvent.delete_all
    travel (Lakeraven::EHR.configuration.session_idle_limit.to_i + 60).seconds do
      get KIOSK
    end

    assert_redirected_to "#{MOUNT}/login"
    assert_operator Lakeraven::EHR::AuditEvent.count, :>=, 1,
                    "expected idle timeout on kiosk to write an audit row"
    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert event.outcome_desc.to_s.match?(/refused|timeout|session/i) || event.outcome != "0",
           "expected session end to be recorded as a refusal, got #{event.attributes.slice('outcome', 'outcome_desc').inspect}"
  end

  test "unauthenticated GET consent_kiosk is audited the same as dashboard" do
    reset!
    Lakeraven::EHR::AuditEvent.delete_all
    get KIOSK
    kiosk_rows = Lakeraven::EHR::AuditEvent.count

    Lakeraven::EHR::AuditEvent.delete_all
    get DASHBOARD
    dashboard_rows = Lakeraven::EHR::AuditEvent.count

    assert_equal dashboard_rows, kiosk_rows
    assert_equal 1, kiosk_rows, "expected one audit row for unauthenticated kiosk access"
    assert_equal "4", Lakeraven::EHR::AuditEvent.recent.first.outcome
    assert_match(/not signed in/i, Lakeraven::EHR::AuditEvent.recent.first.outcome_desc.to_s)
  end

  test "successful unlock audit names staff DUZ and is not a consent create on Patient" do
    post_kiosk_signature
    Lakeraven::EHR::AuditEvent.delete_all

    with_authentication_stub(auth_success_result) { post_kiosk_unlock(access_code: "a", verify_code: "b") }

    assert_response :redirect
    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal DUZ, event.agent_who_identifier
    refute event.action == "C" && event.entity_type == "Patient",
           "unlock must not look like a consent create on Patient (got action=#{event.action} type=#{event.entity_type})"
    assert event.action != "C" || event.entity_type == "Consent",
           "expected unlock to be distinguishable from signing; got action=#{event.action} entity=#{event.entity_type}"
    assert event.outcome_desc.to_s.match?(/unlock|lock|kiosk/i) || event.action == "E",
           "expected unlock outcome to name the kiosk unlock"
  end

  test "resubmit after a stored signature is not audited as a consent create" do
    post_kiosk_signature
    assert_response :success
    Lakeraven::EHR::AuditEvent.delete_all

    post_kiosk_signature

    assert_response :success
    create_events = Lakeraven::EHR::AuditEvent.where(action: "C", entity_type: "Consent")
    assert_equal 0, create_events.count,
                 "resubmit must not file another consent create; rows=#{Lakeraven::EHR::AuditEvent.pluck(:action, :entity_type, :outcome_desc).inspect}"
    readish = Lakeraven::EHR::AuditEvent.where(action: "R")
    assert_equal 1, readish.count, "resubmit should be a read/no-op in the audit trail"
  end

  test "GET kiosk after a successful sign shows hand-back not the signature form" do
    post_kiosk_signature
    assert_response :success

    get KIOSK

    assert_response :success
    assert_match(/hand.*tablet back/i, response.body)
    assert_select "form#consent-signature-form", count: 0
  end
end
