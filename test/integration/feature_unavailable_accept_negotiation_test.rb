# frozen_string_literal: true

require "test_helper"

# SPEC #669 (low): unavailable-response Accept negotiation and HTML audit parity.
class FeatureUnavailableAcceptNegotiationTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include IhsFeatureAvailabilityTestHelper

  PATIENT_DFN = "1"
  IMMUNIZATION_PATH = "/lakeraven-ehr/Immunization"
  SERVICE_REQUEST_PATH = "/lakeraven-ehr/ServiceRequest"

  setup do
    Lakeraven::EHR::AuditEvent.delete_all
    setup_smart_auth(scopes: "system/*.read")
    @fhir_headers = @headers.merge("Accept" => "application/fhir+json")
  end

  teardown do
    teardown_smart_auth
    teardown_restricted_backend
  end

  {
    "application/json" => "text/html;q=0.5, application/json;q=0.9",
    "application/json+fhir" => "text/html;q=0.5, application/json+fhir;q=0.9"
  }.each do |accept_label, accept|
    test "feature unavailable treats Accept #{accept_label} as FHIR JSON in negotiation" do
      with_restricted_backend do
        get IMMUNIZATION_PATH, params: { patient: PATIENT_DFN },
          headers: @headers.merge("Accept" => accept)
        assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
      end
    end
  end

  test "feature unavailable with whitespace before q treats Accept as unusable and renders FHIR JSON" do
    with_restricted_backend do
      get IMMUNIZATION_PATH, params: { patient: PATIENT_DFN },
        headers: @headers.merge("Accept" => "text/html;q =0")
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  test "feature unavailable JSON response records an audit denial for not-supported" do
    with_restricted_backend do
      get IMMUNIZATION_PATH, params: { patient: PATIENT_DFN }, headers: @fhir_headers
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)

      denial = audit_denial_for_fhir_refusal
      refute_nil denial, "JSON not-supported response must record a fhir operation refused audit denial"
      assert_match(/fhir operation refused: not-supported \(HTTP 404\)/i, denial)
    end
  end

  test "feature unavailable HTML response records the same audit denial as JSON" do
    with_restricted_backend do
      get IMMUNIZATION_PATH, params: { patient: PATIENT_DFN },
        headers: @headers.merge("Accept" => "text/html")

      assert_response :not_found
      assert_match(/not available on this system/i, response.body)

      denial = audit_denial_for_fhir_refusal
      refute_nil denial, "HTML not-supported response must record the same audit denial as JSON"
      assert_match(/fhir operation refused: not-supported \(HTTP 404\)/i, denial)
    end
  end

  test "feature unavailable ?_format=application/json matches Accept application/json for JSON body" do
    with_restricted_backend do
      get IMMUNIZATION_PATH,
        params: { patient: PATIENT_DFN, _format: "application/json" },
        headers: @headers.merge("Accept" => "text/html,application/xhtml+xml")
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  test "feature unavailable with explicit application/fhir+json;q=0 prefers HTML over JSON aliases" do
    with_restricted_backend do
      get SERVICE_REQUEST_PATH, params: { patient: PATIENT_DFN },
        headers: @headers.merge(
          "Accept" => "application/fhir+json;q=0, application/json, text/html;q=0.5"
        )

      assert_html_feature_unavailable(response, capability: :prc_referrals)
    end
  end

  test "feature unavailable uses explicit application/fhir+json quality over JSON alias quality" do
    with_restricted_backend do
      get SERVICE_REQUEST_PATH, params: { patient: PATIENT_DFN },
        headers: @headers.merge(
          "Accept" => "application/fhir+json;q=0.2, application/json;q=0.9, text/html;q=0.5"
        )

      assert_html_feature_unavailable(response, capability: :prc_referrals)
    end
  end

  test "feature unavailable FHIR JSON quality includes */* when alias quality is lower" do
    with_restricted_backend do
      get IMMUNIZATION_PATH, params: { patient: PATIENT_DFN },
        headers: @headers.merge(
          "Accept" => "text/html;q=0.5, */*;q=0.9, application/json;q=0.1"
        )

      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  test "feature unavailable FHIR JSON quality includes application/* when alias quality is lower" do
    with_restricted_backend do
      get IMMUNIZATION_PATH, params: { patient: PATIENT_DFN },
        headers: @headers.merge(
          "Accept" => "text/html;q=0.5, application/json;q=0.3, application/*;q=0.9"
        )

      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  test "feature unavailable FHIR JSON quality includes */* when alias qualities are zero" do
    with_restricted_backend do
      get IMMUNIZATION_PATH, params: { patient: PATIENT_DFN },
        headers: @headers.merge(
          "Accept" => "application/json;q=0, application/json+fhir;q=0, text/html;q=0.1, */*;q=0.5"
        )

      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  test "feature unavailable without wildcard alias quality alone decides HTML over JSON" do
    with_restricted_backend do
      get IMMUNIZATION_PATH, params: { patient: PATIENT_DFN },
        headers: @headers.merge("Accept" => "text/html;q=0.5, application/json;q=0.3")

      assert_html_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  private

  def audit_denial_for_fhir_refusal
    Lakeraven::EHR::AuditEvent.order(:id).find do |event|
      event.outcome_desc.to_s.match?(/fhir operation refused: not-supported \(HTTP 404\)/i)
    end&.outcome_desc
  end

  def assert_html_feature_unavailable(response, capability:)
    assert_response :not_found
    assert_equal "text/html", response.media_type
    assert_match(/not available on this system/i, response.body)
    refute_equal "OperationOutcome", JSON.parse(response.body).fetch("resourceType", nil)
  rescue JSON::ParserError
    # HTML body is expected
  end
end
