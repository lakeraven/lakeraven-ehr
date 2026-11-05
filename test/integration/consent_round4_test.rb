# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

class ConsentRound4Test < ActionDispatch::IntegrationTest
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
    if @demo_original_client
      RpmsRpc.configure { |c| c.client = @demo_original_client }
      @demo_original_client = nil
    end
  end

  test "kiosk signature POST with NUL byte in signer_name answers 422 counts refusal and stores nothing" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    before = lock.refused_signature_count

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(signer_name: "SYNTHETIC\u0000SIGNER")
    end

    assert_response :unprocessable_entity
    assert_equal before + 1, lock.reload.refused_signature_count
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "kiosk signature POST with invalid UTF-8 signer_name is refused before decode with nothing stored" do
    open_kiosk_via_handover!

    decode_tally = nil
    count_decode_signature_data_url_calls do |tally|
      assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
        post_kiosk_signature(signer_name: invalid_utf8_signer_name)
      end
      decode_tally = tally
    end

    assert_includes [ 400, 422 ], response.status, "invalid UTF-8 form body may be refused by Rails or the kiosk"
    assert_equal 0, decode_tally.count if response.status == 400
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "revocation POST with NUL byte in reason answers 422 and stores no revocation row" do
    refresh_clinician_security_keys!(%w[orders_sign])
    signature = Lakeraven::EHR::SignedConsent.create!(
      patient_dfn: DFN,
      consent_template: Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH),
      template_key: TEMPLATE_BH,
      template_version: 1,
      template_body_digest: body_digest(Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH).body),
      signature_png: TINY_PNG,
      signed_at: Time.zone.now,
      witness_duz: DUZ,
      kind: "signature",
      recorded_by_duz: DUZ
    )

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.where(kind: "revocation").count } do
      post "#{BASE}/#{signature.id}/revocation",
           params: { reason: "SYNTHETIC\u0000REVOCATION", authenticity_token: csrf_token }
    end

    assert_response :unprocessable_entity
  end

  test "atomic refusal cap blocks decode when DB is at MAX but stale memory says not exhausted" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    lock.update_column(:refused_signature_count, Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES)

    decode_tally = nil
    with_stale_kiosk_lock_refusal_check! do
      count_decode_signature_data_url_calls do |tally|
        post_kiosk_signature(signature: signature_data_url(pad_sized_visible_signature_png))
        decode_tally = tally
      end
    end

    assert_response :too_many_requests
    assert_equal 0, decode_tally.count
    assert_operator lock.reload.refused_signature_count, :<=, Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES
  end

  test "after MAX refused posts the next post answers 429 without decode and count never exceeds MAX" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    bad = signature_data_url(magic_bytes_only_png)

    Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES.times do
      post_kiosk_signature(signature: bad)
      assert_response :unprocessable_entity
    end
    assert_equal Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES, lock.reload.refused_signature_count

    decode_tally = nil
    count_decode_signature_data_url_calls do |tally|
      post_kiosk_signature(signature: signature_data_url(pad_sized_visible_signature_png))
      decode_tally = tally
    end

    assert_response :too_many_requests
    assert_equal 0, decode_tally.count
    assert_equal Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES, lock.reload.refused_signature_count
  end

  test "stale not-exhausted check with DB at MAX minus one still respects cap without exceeding MAX in DB" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    lock.update_column(:refused_signature_count, Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES - 1)

    with_stale_kiosk_lock_refusal_check! do
      post_kiosk_signature(signature: signature_data_url(magic_bytes_only_png))
    end
    assert_response :unprocessable_entity
    assert_equal Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES, lock.reload.refused_signature_count

    decode_tally = nil
    with_stale_kiosk_lock_refusal_check! do
      count_decode_signature_data_url_calls do |tally|
        post_kiosk_signature(signature: signature_data_url(pad_sized_visible_signature_png))
        decode_tally = tally
      end
    end

    assert_response :too_many_requests
    assert_equal 0, decode_tally.count
    assert_equal Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES, lock.reload.refused_signature_count
  end

  {
    "APNG acTL fcTL fdAT" => :apng_extra_blank_frame_pad_png,
    "gAMA extreme" => :gama_extreme_pad_png,
    "iCCP" => :iccp_pad_png,
    "tEXt" => :text_pad_png,
    "sRGB" => :srgb_pad_png
  }.each do |label, builder|
    test "kiosk refuses otherwise inked pad PNG carrying disallowed #{label} chunk with 422 and nothing stored" do
      open_kiosk_via_handover!
      bytes = send(builder)

      assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
        post_kiosk_signature(signature: signature_data_url(bytes))
      end

      assert_response :unprocessable_entity, "expected #{label} PNG to be refused by chunk allow-list"
    end
  end

  test "plain IHDR IDAT IEND pad inked PNGs remain accepted on the kiosk" do
    open_kiosk_via_handover!

    assert_difference -> { Lakeraven::EHR::SignedConsent.count }, +1 do
      post_kiosk_signature(signature: signature_data_url(pad_sized_visible_signature_png))
    end
    assert_response :success

    reset_open_consent_kiosk_lock!
    post_handover
    follow_redirect!

    assert_difference -> { Lakeraven::EHR::SignedConsent.count }, +1 do
      post_kiosk_signature(signature: signature_data_url(dark_stroke_on_white_pad_png))
    end
    assert_response :success
  end

  test "POST test_session rpms_idle_seconds is stored and ends WebController session before site idle limit" do
    Lakeraven::EHR.configuration.session_idle_limit = 15.minutes
    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, rpms_idle_seconds: 600)

    travel 11.minutes do
      get DASHBOARD
    end

    assert_redirected_to "#{MOUNT}/login"
  end

  test "kiosk GET after 11 minutes with RPMS idle 600s redirects to login and audits session timed out" do
    Lakeraven::EHR.configuration.session_idle_limit = 15.minutes
    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, rpms_idle_seconds: 600)
    open_patient_context!(DFN)
    post_handover
    follow_redirect!
    Lakeraven::EHR::AuditEvent.delete_all

    travel 11.minutes do
      get KIOSK
    end

    assert_redirected_to "#{MOUNT}/login"
    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert event, "expected audit denial when RPMS idle ends session on kiosk"
    assert_match(/session timed out/i, event.outcome_desc.to_s)
  end

  test "staff consent list GET after 11 minutes with RPMS idle 600s redirects to login" do
    Lakeraven::EHR.configuration.session_idle_limit = 15.minutes
    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, rpms_idle_seconds: 600)
    open_patient_context!(DFN)

    travel 11.minutes do
      get BASE
    end

    assert_redirected_to "#{MOUNT}/login"
  end

  test "kiosk still renders at 9 minutes when RPMS idle is 600 seconds and site limit is 15 minutes" do
    Lakeraven::EHR.configuration.session_idle_limit = 15.minutes
    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, rpms_idle_seconds: 600)
    open_patient_context!(DFN)
    post_handover
    follow_redirect!

    travel 9.minutes do
      get KIOSK
    end

    assert_response :success
  end

  test "consent.revoke capability is met only by orders_sign or orders_release" do
    assert Lakeraven::EHR::Capabilities.allows?(%w[orders_sign], "consent.revoke")
    assert Lakeraven::EHR::Capabilities.allows?(%w[orders_release], "consent.revoke")
    refute Lakeraven::EHR::Capabilities.allows?(%w[registration_menu], "consent.revoke")
    refute Lakeraven::EHR::Capabilities.allows?(%w[orders_enter], "consent.revoke")
    refute Lakeraven::EHR::Capabilities.allows?(%w[scheduling_user], "consent.revoke")
    refute Lakeraven::EHR::Capabilities.allows?([], "consent.revoke")
  end

  test "registration clerk can handover but revocation POST is forbidden with audit and no row" do
    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, security_keys: %w[registration_menu])
    open_patient_context!(DFN)
    signature = Lakeraven::EHR::SignedConsent.create!(
      patient_dfn: DFN,
      consent_template: Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH),
      template_key: TEMPLATE_BH,
      template_version: 1,
      template_body_digest: body_digest(Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH).body),
      signature_png: TINY_PNG,
      signed_at: Time.zone.now,
      witness_duz: DUZ,
      kind: "signature",
      recorded_by_duz: DUZ
    )
    Lakeraven::EHR::AuditEvent.delete_all

    post_handover
    assert_response :redirect
    assert Lakeraven::EHR::KioskLock.exists?

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.where(kind: "revocation").count } do
      post "#{BASE}/#{signature.id}/revocation",
           params: { reason: SYNTHETIC_REVOCATION_REASON, authenticity_token: csrf_token }
    end
    assert_locked_redirect_to_kiosk!

    reset_open_consent_kiosk_lock!

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.where(kind: "revocation").count } do
      post "#{BASE}/#{signature.id}/revocation",
           params: { reason: SYNTHETIC_REVOCATION_REASON, authenticity_token: csrf_token }
    end

    assert_response :forbidden
    assert_operator Lakeraven::EHR::AuditEvent.count, :>=, 1
  end

  test "registration clerk consent list omits revoke control clinician sees it and can revoke" do
    signature = Lakeraven::EHR::SignedConsent.create!(
      patient_dfn: DFN,
      consent_template: Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH),
      template_key: TEMPLATE_BH,
      template_version: 1,
      template_body_digest: body_digest(Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH).body),
      signature_png: TINY_PNG,
      signed_at: Time.zone.now,
      witness_duz: DUZ,
      kind: "signature",
      recorded_by_duz: DUZ
    )

    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, security_keys: %w[registration_menu])
    open_patient_context!(DFN)
    get BASE
    assert_response :ok
    assert_select "form[action=?]", "#{BASE}/#{signature.id}/revocation", count: 0

    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, security_keys: %w[orders_sign])
    open_patient_context!(DFN)
    get BASE
    assert_select "form[action=?][method=post]", "#{BASE}/#{signature.id}/revocation"

    assert_difference -> { Lakeraven::EHR::SignedConsent.where(kind: "revocation").count }, +1 do
      post "#{BASE}/#{signature.id}/revocation",
           params: { reason: SYNTHETIC_REVOCATION_REASON, authenticity_token: csrf_token }
    end
    assert_response :redirect
  end

  test "application layout pages include consent kiosk BroadcastChannel listener with handover messages" do
    reset_open_consent_kiosk_lock!

    get CHART
    assert_response :ok
    assert_consent_kiosk_listener_script!

    get BASE
    assert_response :ok
    assert_consent_kiosk_listener_script!
  end

  test "kiosk page posts handover-started on the consent kiosk channel" do
    open_kiosk_via_handover!
    assert_select 'script[data-consent-kiosk-announce="handover-started"]', count: 1 do |scripts|
      text = scripts.first.text
      assert_includes text, CONSENT_KIOSK_BROADCAST_CHANNEL
    end
  end

  test "kiosk layout does not install a listener that navigates away on handover-started" do
    open_kiosk_via_handover!
    assert_select "script[data-consent-kiosk-listener]" do |scripts|
      scripts.each do |script|
        text = script.text
        refute_includes text, KIOSK,
                        "kiosk listener must not redirect to kiosk via location on handover-started"
        refute_match(/location\.replace\s*\(/, text,
                     "kiosk listener must not navigate away on handover-started")
      end
    end
  end

  test "first GET after unlock posts handover-ended once not on a later GET" do
    open_kiosk_via_handover!
    post_kiosk_signature
    assert_response :success

    with_authentication_stub(auth_success_result) do
      post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
    end
    follow_redirect!

    assert_select 'script[data-consent-kiosk-announce="handover-ended"]', count: 1 do |scripts|
      text = scripts.first.text
      assert_includes text, CONSENT_KIOSK_BROADCAST_CHANNEL
    end

    get BASE
    assert_response :ok
    assert_select 'script[data-consent-kiosk-announce="handover-ended"]', count: 0
    assert_consent_kiosk_listener_script!
  end

  def assert_consent_kiosk_listener_script!
    assert_select "script[data-consent-kiosk-listener]", count: 1 do |scripts|
      text = scripts.first.text
      assert_includes text, CONSENT_KIOSK_BROADCAST_CHANNEL
      assert_includes text, "handover-started"
      assert_includes text, "handover-ended"
      assert_includes text, KIOSK
    end
  end
  private :assert_consent_kiosk_listener_script!
end
