# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

# Audit-fidelity specification for PR #805 / #793 (kiosk handover token ordering
# and refusal outcome_desc). Intentionally fail until implemented.
class ConsentPr805AuditTest < ActionDispatch::IntegrationTest
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

  test "mismatched handover_token POST after stored signature refuses 422 counts refusal and audits denial not read" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    current_token = lock.handover_token

    post_kiosk_signature(handover_token: current_token)
    assert_response :success
    assert_equal 1, Lakeraven::EHR::SignedConsent.count

    refused_before = lock.reload.refused_signature_count
    mismatched = SecureRandom.uuid
    refute_equal current_token, mismatched

    Lakeraven::EHR::AuditEvent.delete_all

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(handover_token: mismatched)
    end

    assert_response :unprocessable_entity
    assert_equal refused_before + 1, lock.reload.refused_signature_count

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert event, "expected audit row for mismatched token after stored signature"
    assert_equal "4", event.outcome
    refute event.action == "R" && event.outcome == "0",
           "stale or mismatched token must not audit as stored-signature read (got action=#{event.action} outcome=#{event.outcome})"
  end

  test "correct handover_token double-tap after stored signature hand-backs 200 without refusal increment or second consent row" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    current_token = lock.handover_token

    post_kiosk_signature(handover_token: current_token)
    assert_response :success

    refused_before = lock.reload.refused_signature_count
    Lakeraven::EHR::AuditEvent.delete_all

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(handover_token: current_token)
    end

    assert_response :success
    assert_equal refused_before, lock.reload.refused_signature_count

    read_events = Lakeraven::EHR::AuditEvent.where(action: "R", outcome: "0")
    assert_equal 1, read_events.count,
                 "double-tap with matching token should audit one successful read, got #{Lakeraven::EHR::AuditEvent.pluck(:action, :outcome, :outcome_desc).inspect}"
  end

  test "kiosk POST with mismatched handover_token audit outcome_desc names handover token" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    Lakeraven::EHR::AuditEvent.delete_all

    post_kiosk_signature(handover_token: SecureRandom.uuid)
    assert_response :unprocessable_entity

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal "4", event.outcome
    assert_match(/handover token/i, event.outcome_desc.to_s,
                 "token mismatch refusal must describe handover token; got #{event.outcome_desc.inspect}")
  end

  test "kiosk POST with bad PNG audit outcome_desc does not name handover token" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    Lakeraven::EHR::AuditEvent.delete_all

    post_kiosk_signature(
      handover_token: lock.handover_token,
      signature: signature_data_url(magic_bytes_only_png)
    )
    assert_response :unprocessable_entity

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal "4", event.outcome
    assert event.outcome_desc.present?,
           "bad PNG refusal must record a reason distinct from handover-token mismatch"
    refute_match(/handover token/i, event.outcome_desc.to_s,
                 "bad PNG refusal must not look like handover-token mismatch; got #{event.outcome_desc.inspect}")
  end

  test "kiosk POST with invalid signer_name audit outcome_desc does not name handover token" do
    open_kiosk_via_handover!
    lock = kiosk_lock_row
    Lakeraven::EHR::AuditEvent.delete_all

    post_kiosk_signature(
      handover_token: lock.handover_token,
      signer_name: "SYNTHETIC\u0000SIGNER"
    )
    assert_response :unprocessable_entity

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal "4", event.outcome
    assert event.outcome_desc.present?,
           "signer-name refusal must record a reason distinct from handover-token mismatch"
    refute_match(/handover token/i, event.outcome_desc.to_s,
                 "signer-name refusal must not look like handover-token mismatch; got #{event.outcome_desc.inspect}")
  end
end
