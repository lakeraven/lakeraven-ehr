# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

class ConsentRound5Test < ActionDispatch::IntegrationTest
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

  test "staff consent list GET after RPMS idle timeout redirects to login and audits session timed out for DUZ" do
    Lakeraven::EHR.configuration.session_idle_limit = 15.minutes
    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, rpms_idle_seconds: 600)
    open_patient_context!(DFN)
    Lakeraven::EHR::AuditEvent.delete_all

    travel 11.minutes do
      get BASE
    end

    assert_redirected_to "#{MOUNT}/login"
    assert_equal 1, Lakeraven::EHR::AuditEvent.count, "expected one audit row when staff session times out on consent list"
    event = Lakeraven::EHR::AuditEvent.sole
    assert_match(/session timed out/i, event.outcome_desc.to_s)
    assert_equal DUZ, event.agent_who_identifier
  end

  test "staff revocation POST after RPMS idle timeout redirects to login audits session timed out and stores no revocation" do
    Lakeraven::EHR.configuration.session_idle_limit = 15.minutes
    reset!
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES, rpms_idle_seconds: 600, security_keys: %w[orders_sign])
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
    token = csrf_token
    Lakeraven::EHR::AuditEvent.delete_all

    travel 11.minutes do
      assert_no_difference -> { Lakeraven::EHR::SignedConsent.where(kind: "revocation").count } do
        post "#{BASE}/#{signature.id}/revocation",
             params: { reason: SYNTHETIC_REVOCATION_REASON, authenticity_token: token }
      end
    end

    assert_redirected_to "#{MOUNT}/login"
    assert_equal 1, Lakeraven::EHR::AuditEvent.count, "expected one audit row when staff session times out on revocation"
    event = Lakeraven::EHR::AuditEvent.sole
    assert_match(/session timed out/i, event.outcome_desc.to_s)
    assert_equal DUZ, event.agent_who_identifier
  end

  test "kiosk POST with array signer_name is refused with nothing stored and tablet stays locked" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    before = lock.refused_signature_count
    bad_name = [ "SYNTHETIC\u0000A", "B" ]

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(signer_name: bad_name)
    end

    assert_response :unprocessable_entity
    assert_equal before + 1, lock.reload.refused_signature_count
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "kiosk POST with hash signer_name is refused with nothing stored and tablet stays locked" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    before = lock.refused_signature_count

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(signer_name: { "x" => "y" })
    end

    assert_response :unprocessable_entity
    assert_equal before + 1, lock.reload.refused_signature_count
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "revocation POST with non-string reason answers 422 and stores no revocation row" do
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

    [ [ "a", "b" ], { "x" => "y" } ].each do |bad_reason|
      assert_no_difference -> { Lakeraven::EHR::SignedConsent.where(kind: "revocation").count } do
        post "#{BASE}/#{signature.id}/revocation",
             params: { reason: bad_reason, authenticity_token: csrf_token }
      end
      assert_response :unprocessable_entity
    end
  end

  test "page after unlock announces handover-ended on the same script element as the kiosk listener" do
    open_kiosk_via_handover!
    post_kiosk_signature
    assert_response :success

    with_authentication_stub(auth_success_result) do
      post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
    end
    follow_redirect!

    assert_select "script[data-consent-kiosk-listener][data-consent-kiosk-announce=?]",
                    "handover-ended",
                    count: 1
    assert_select "script[data-consent-kiosk-listener]", count: 1
  end

  test "unreadable locked template refusal respects MAX with stale exhaustion check and second post answers 429" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    lock.update_column(:refused_signature_count, Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES - 1)
    Lakeraven::EHR::ConsentTemplate.delete_all

    with_stale_kiosk_lock_refusal_check! do
      post_kiosk_signature(signature: signature_data_url(magic_bytes_only_png))
    end
    assert_response :unprocessable_entity
    assert_equal Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES, lock.reload.refused_signature_count

    with_stale_kiosk_lock_refusal_check! do
      post_kiosk_signature(signature: signature_data_url(pad_sized_visible_signature_png))
    end
    assert_response :too_many_requests
    assert_equal Lakeraven::EHR::KioskLock::MAX_REFUSED_SIGNATURES, lock.reload.refused_signature_count
  end
end

module Lakeraven
  module EHR
    class SignedConsentRound5Test < ActiveSupport::TestCase
      include ConsentWriteTestHelper

      test "acceptable_text? rejects non-string-like values and accepts plain text and nil" do
        refute SignedConsent.acceptable_text?([ "a" ])
        refute SignedConsent.acceptable_text?({ "x" => "y" })
        assert SignedConsent.acceptable_text?("SYNTHETIC SIGNER")
        assert SignedConsent.acceptable_text?(nil)
      end
    end
  end
end
