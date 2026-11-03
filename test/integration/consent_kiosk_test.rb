# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

class ConsentKioskTest < ActionDispatch::IntegrationTest
  include ConsentWriteTestHelper

  LOCKED_ROUTE_ASSERTIONS = [
    [ :get, CHART, "chart" ],
    [ :get, BASE, "consent list" ],
    [ :get, "#{MOUNT}/patients/#{OTHER_DFN}/consents", "another patient's consents" ],
    [ :get, DASHBOARD, "dashboard" ],
    [ :get, CHART_SEARCH, "chart search" ],
    [ :post, PATIENT_SEARCH, "patient search" ],
    [ :get, "#{MOUNT}/patients/#{DFN}/screenings", "screenings" ],
    [ :get, "#{MOUNT}/patients/#{DFN}/allergies/new", "allergies" ],
    [ :post, HANDOVER, "handover" ]
  ].freeze

  setup do
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
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
    teardown_oauth!
    Lakeraven::EHR::AuditEvent.delete_all
    SignedConsent.delete_all if defined?(Lakeraven::EHR::SignedConsent) && Lakeraven::EHR::SignedConsent.table_exists?
    ConsentTemplate.delete_all if defined?(Lakeraven::EHR::ConsentTemplate) && Lakeraven::EHR::ConsentTemplate.table_exists?
    if @demo_original_client
      RpmsRpc.configure { |c| c.client = @demo_original_client }
      @demo_original_client = nil
    end
  end

  test "kiosk shows template title and body with patient name and date of birth only" do
    template = Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH)

    assert_response :ok
    assert_includes response.body, template.title
    assert_includes response.body, template.body
    assert_includes response.body, demo_patient_display_name
    assert_includes response.body, demo_patient_dob_fragment

    refute_includes response.body, "900-00-0103"
    refute_includes response.body, "Prenatal Vitamin"
    refute_includes response.body, "Iron deficiency"
  end

  test "kiosk exposes no navigation links search forms or outbound anchors" do
    assert_select "a[href]", count: 0
    assert_select "form[action=?]", CHART_SEARCH, count: 0
    assert_select "form#patient-search", count: 0
    assert_select "nav", count: 0

    allowed_actions = [ KIOSK, "#{KIOSK}/unlock" ]
    css_select("form").each do |form|
      action = form["action"].to_s
      action = "#{MOUNT}#{action}" if action.start_with?("/lakeraven-ehr")
      assert allowed_actions.any? { |path| action.end_with?(path) },
             "unexpected form action #{action.inspect}"
    end
  end

  test "GET kiosk is audited without embedding signature bytes" do
    Lakeraven::EHR::AuditEvent.delete_all

    get KIOSK

    assert_response :ok
    assert_equal 1, Lakeraven::EHR::AuditEvent.count
    refute_signature_phi_in_audit_rows!
  end

  test "POST kiosk stores signed consent with witness staff DUZ and shows hand-back page" do
    Lakeraven::EHR::AuditEvent.delete_all

    logs = capture_rails_logs do
      assert_difference -> { Lakeraven::EHR::SignedConsent.count }, +1 do
        post_kiosk_signature
      end
    end

    assert_response :success
    assert_match(/hand.*tablet back/i, response.body)

    row = Lakeraven::EHR::SignedConsent.order(:id).last
    assert_equal DFN, row.patient_dfn
    assert_equal DUZ, row.witness_duz
    assert_equal TEMPLATE_BH, row.template_key
    assert row.signature_png.start_with?(PNG_MAGIC)
    assert_equal SYNTHETIC_SIGNER_NAME, row.signer_name

    event = Lakeraven::EHR::AuditEvent.recent.first
    assert_equal "C", event.action
    assert_equal "Consent", event.entity_type
    assert_equal row.id.to_s, event.entity_identifier
    refute_signature_phi_in_audit_rows!
    refute_signature_phi_in_logs!(logs)
  end

  test "blank signature returns 422 stores nothing and stays locked" do
    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature(signature: "")
    end

    assert_response :unprocessable_entity
    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "second submit after a successful sign stores nothing new" do
    post_kiosk_signature
    assert_response :success

    assert_no_difference -> { Lakeraven::EHR::SignedConsent.count } do
      post_kiosk_signature
    end
  end

  test "unlock succeeds only when re-auth returns the same DUZ" do
    post_kiosk_signature
    assert_response :success

    with_authentication_stub(auth_success_result(duz: DUZ)) do
      post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
    end

    assert_redirected_to BASE
    get CHART
    assert_response :ok
  end

  test "unlock refuses wrong codes different DUZ or failed auth" do
    post_kiosk_signature

    with_authentication_stub(auth_failure_result) do
      post_kiosk_unlock(access_code: "bad", verify_code: "bad")
    end
    assert_includes [ 422, 302 ], response.status

    with_authentication_stub(auth_success_result(duz: "12345")) do
      post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
    end
    assert_includes [ 422, 302 ], response.status
    follow_redirect! if response.redirect?
    assert_equal KIOSK, URI.parse(request.url).path if response.success?

    get CHART
    assert_locked_redirect_to_kiosk!
  end

  test "while locked other engine pages redirect to the kiosk" do
    LOCKED_ROUTE_ASSERTIONS.each do |verb, path, label|
      send(verb, path, params: post_params_for(path))
      assert_locked_redirect_to_kiosk!("expected #{label} (#{verb} #{path}) to stay locked")
    end
  end

  private

  def post_params_for(path)
    params = { authenticity_token: csrf_token }
    params[:template_key] = TEMPLATE_BH if path == HANDOVER
    params[:q] = "DEMOPATIENT" if path == PATIENT_SEARCH
    params
  end
end
