# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

# PR #805 thread 5: prove decode_signature_data_url call counter is live.
class ConsentPr805DecodeCounterTest < ActionDispatch::IntegrationTest
  include ConsentWriteTestHelper

  setup do
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::AuditEvent.delete_all
    @demo_original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES)
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

  test "successful kiosk signature POST increments the decode counter" do
    handover_token = kiosk_lock_row.handover_token
    tally = nil

    count_decode_signature_data_url_calls do |counter|
      assert_difference -> { Lakeraven::EHR::SignedConsent.count }, +1 do
        post_kiosk_signature(handover_token: handover_token)
      end
      assert_response :success
      tally = counter
    end

    assert_operator tally.count, :>=, 1,
                    "expected decode_signature_data_url to run on a valid signature POST"
  end
end
