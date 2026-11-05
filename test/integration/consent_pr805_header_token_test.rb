# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

# PR #805 thread 1: kiosk must refuse a SMART-launched Bearer header beside the
# staff cookie session that owns the kiosk lock.
class ConsentPr805HeaderTokenTest < ActionDispatch::IntegrationTest
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
    open_kiosk_via_handover!(template_key: TEMPLATE_BH)
    @launched_token = create_smart_launched_consent_token!
    @template = Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH)
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
    Lakeraven::EHR::LoginThrottle.reset!
    teardown_oauth!
    Lakeraven::EHR::AuditEvent.delete_all
    Lakeraven::EHR::SignedConsent.delete_all if Lakeraven::EHR::SignedConsent.table_exists?
    Lakeraven::EHR::KioskLock.delete_all if Lakeraven::EHR::KioskLock.table_exists?
    Lakeraven::EHR::ConsentTemplate.delete_all if Lakeraven::EHR::ConsentTemplate.table_exists?
    Lakeraven::EHR::SmartAuthorization.delete_all if Lakeraven::EHR::SmartAuthorization.table_exists?
    Lakeraven::EHR.reset_configuration!
    if @demo_original_client
      RpmsRpc.configure { |c| c.client = @demo_original_client }
      @demo_original_client = nil
    end
  end

  test "cookie-only kiosk GET and POST succeed as control" do
    get KIOSK
    assert_response :success
    assert_includes response.body, @template.title

    handover_token = kiosk_lock_row.handover_token
    assert_difference -> { Lakeraven::EHR::SignedConsent.count }, +1 do
      post_kiosk_signature(handover_token: handover_token)
    end
    assert_response :success
  end

  test "kiosk GET with a different browser SSO bearer beside the session token is refused before credential check" do
    alternate = clinician_token(scopes: WRITE_SCOPES, duz: DUZ)
    refute_equal @clinician_token.id, alternate.id

    headers = launched_bearer_headers(alternate)

    get KIOSK, headers: headers
    assert_response :unauthorized
    refute_includes response.body, @template.title
    refute_includes response.body, demo_patient_display_name
    refute_includes response.body, demo_patient_dob_fragment
    assert_match(/invalid or revoked token/i, response.body)
  end

  test "kiosk session credential requires authenticated token id to match session smart token" do
    alternate = clinician_token(scopes: WRITE_SCOPES, duz: DUZ)
    refute_equal @clinician_token.id, alternate.id

    assert consent_kiosk_controller_for_credential_probe(current_token: alternate)
             .send(:clinician_credential?),
           "alternate browser SSO token must satisfy clinician_credential?"
    refute consent_kiosk_controller_for_credential_probe(current_token: alternate)
             .send(:kiosk_session_credential?),
           "session_access_token id must match current_token id"

    controller = consent_kiosk_controller_for_credential_probe(current_token: alternate)
    refute controller.performed?, "controller must be unrendered before require_clinician_credential!"
    refute controller.send(:require_clinician_credential!)
    assert_equal 403, controller.response.status
  end

  test "kiosk GET and POST with launched Bearer beside staff cookie are refused audited and leak nothing" do
    Lakeraven::EHR::SignedConsent.delete_all
    Lakeraven::EHR::AuditEvent.delete_all
    headers = launched_bearer_headers(@launched_token)

    get KIOSK, headers: headers
    assert_includes [ 401, 403 ], response.status
    refute_includes response.body, @template.title
    refute_includes response.body, demo_patient_display_name
    refute_includes response.body, demo_patient_dob_fragment
    get_audit = Lakeraven::EHR::AuditEvent.order(:id).last
    assert get_audit, "expected audit row for kiosk GET with mismatched launched bearer"
    assert_equal "4", get_audit.outcome

    Lakeraven::EHR::AuditEvent.delete_all
    handover_token = kiosk_lock_row.handover_token

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post KIOSK,
           params: {
             signature: signature_data_url,
             signer_name: SYNTHETIC_SIGNER_NAME,
             handover_token: handover_token,
             authenticity_token: csrf_token
           },
           headers: headers
    end
    assert_includes [ 401, 403 ], response.status
    post_audit = Lakeraven::EHR::AuditEvent.order(:id).last
    assert post_audit, "expected audit row for kiosk POST with mismatched launched bearer"
    assert_equal "4", post_audit.outcome
  end

  private

  def consent_kiosk_controller_for_credential_probe(current_token:)
    Lakeraven::EHR::ConsentKioskController.new.tap do |controller|
      request = ActionController::TestRequest.create(Lakeraven::EHR::ConsentKioskController)
      request.session[:duz] = DUZ
      request.session[:smart_token] = @clinician_token.plaintext_token || @clinician_token.token
      controller.set_request!(request)
      controller.set_response!(ActionController::Base.make_response!(request))
      controller.instance_variable_set(:@current_token, current_token)
    end
  end

  def create_smart_launched_consent_token!(duz: DUZ, scopes: WRITE_SCOPES)
    app = Doorkeeper::Application.create!(
      name: "pr805-launched-consent",
      redirect_uri: "https://example.test/callback",
      scopes: scopes,
      confidential: true
    )
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(SecureRandom.urlsafe_base64(48)), padding: false)
    authorization = Lakeraven::EHR::SmartAuthorization.create!(
      application: app,
      redirect_uri: "https://example.test/callback",
      code_challenge: challenge,
      code_digest: Lakeraven::EHR::SmartAuthorization.digest(SecureRandom.urlsafe_base64(32)),
      scopes: scopes,
      session_token: @clinician_token,
      duz: duz.to_s,
      expires_at: Lakeraven::EHR::SmartAuthorization::CODE_LIFETIME.from_now,
      redeemed_at: Time.current
    )
    authorization.issue_access_token!
  end

  def launched_bearer_headers(token)
    raw = token.plaintext_token || token.token
    { "Authorization" => "Bearer #{raw}" }
  end
end
