# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

class ConsentSpecAmendmentR3Test < ActionDispatch::IntegrationTest
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
    Lakeraven::EHR::KioskLock.delete_all if Lakeraven::EHR::KioskLock.table_exists?
    Lakeraven::EHR::ConsentTemplate.delete_all if Lakeraven::EHR::ConsentTemplate.table_exists?
    Lakeraven::EHR.reset_configuration!
    if @demo_original_client
      RpmsRpc.configure { |c| c.client = @demo_original_client }
      @demo_original_client = nil
    end
  end

  test "blank alpha pad PNGs are refused over HTTP with nothing stored" do
    [
      [ "opaque white RGBA", blank_opaque_white_rgba_pad_png ],
      [ "opaque white grey+alpha", blank_opaque_white_graya_pad_png ],
      [ "near-white on transparent", near_white_ink_on_transparent_pad_png ]
    ].each do |label, bytes|
      Lakeraven::EHR::SignedConsent.delete_all

      assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
        post_kiosk_signature(signature: signature_data_url(bytes))
      end

      assert_response :unprocessable_entity, "expected #{label} to be refused"
    end
  end

  test "pad dimension limits refuse oversize PNGs and accept 1800 by 600 ink" do
    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(signature: signature_data_url(overwide_pad_signature_png))
    end
    assert_response :unprocessable_entity

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(signature: signature_data_url(overtall_pad_signature_png))
    end
    assert_response :unprocessable_entity

    assert_difference -> { Lakeraven::EHR::SignedConsent.count }, +1 do
      post_kiosk_signature(signature: signature_data_url(max_pad_dimension_signature_png(width: 1800, height: 600)))
    end
    assert_response :success
  end

  test "after ten refused signature posts further posts answer 429 without decoding" do
    bad = signature_data_url(magic_bytes_only_png)
    10.times do
      post_kiosk_signature(signature: bad)
      assert_response :unprocessable_entity
    end

    decode_calls = nil
    count_decode_signature_data_url_calls do |calls|
      post_kiosk_signature(signature: signature_data_url(max_pad_dimension_signature_png(width: 1800, height: 600)))
      decode_calls = calls
    end

    assert_response :too_many_requests
    assert_match(/too many|refused|signature/i, response.body)
    assert_equal 0, decode_calls, "429 must short-circuit before decode_signature_data_url runs"
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "second handover reaching the lock write refuses without changing the stored lock" do
    first = Lakeraven::EHR::KioskLock.sole.attributes.slice("template_key", "handover_token")
    Lakeraven::EHR::AuditEvent.delete_all

    with_second_handover_reaching_lock_write do
      post_handover(template_key: TEMPLATE_TELEHEALTH)
    end

    second = Lakeraven::EHR::KioskLock.sole.attributes.slice("template_key", "handover_token")
    assert_equal first, second, "a locked handover must not overwrite template or handover token"

    refute_equal 503, response.status
    assert_includes [ 422, 302 ], response.status
    if response.redirect?
      assert_equal KIOSK, URI.parse(response.location).path
    else
      assert_match(/refused|locked/i, response.body)
    end

    refusal = Lakeraven::EHR::AuditEvent.order(:id).last
    assert refusal, "expected a refusal audit row for the second handover"
    assert_match(/refused|handover|lock/i, refusal.outcome_desc.to_s)
  end

  test "concurrent double Sign stores one row and audits the racing loser as read not create" do
    post_kiosk_signature
    assert_response :success
    Lakeraven::EHR::AuditEvent.delete_all

    with_racing_kiosk_sign_loser do
      post_kiosk_signature
    end

    assert_equal 1, Lakeraven::EHR::SignedConsent.where(kind: "signature").count
    create_events = Lakeraven::EHR::AuditEvent.where(action: "C", entity_type: "Consent")
    assert_equal 0, create_events.count,
                 "loser must not be audited as a second consent create; rows=#{Lakeraven::EHR::AuditEvent.pluck(:action, :entity_type).inspect}"
    read_events = Lakeraven::EHR::AuditEvent.where(action: "R")
    assert_equal 1, read_events.count, "loser should be audited as a read"
  end

  test "another clinician whose verify code must change counts as a failed unlock in LoginThrottle" do
    post_kiosk_signature
    assert_response :success

    access = "SYNTHETIC.OTHER.ACCESS"
    verify = "SYNTHETIC.OTHER.VERIFY"
    other_duz = "88888"
    failures_before = login_throttle_failures_for(access)

    with_authentication_stub(auth_verify_must_change_result(duz: other_duz)) do
      post_kiosk_unlock(access_code: access, verify_code: verify)
    end

    assert_includes [ 422, 403 ], response.status
    assert_operator login_throttle_failures_for(access), :>, failures_before,
                    "verify_needs_change for a different DUZ must record a LoginThrottle failure"
    get CHART
    assert_locked_redirect_to_kiosk!
  end
end
