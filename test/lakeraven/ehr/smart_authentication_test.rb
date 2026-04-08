# frozen_string_literal: true

require "test_helper"

# A throwaway controller used to exercise SmartAuthentication's
# behavior in isolation. We don't reuse PatientsController because
# the test would have to set up an adapter and tenant context just
# to verify Bearer behavior.
class SmartAuthTestController < ::ActionController::API
  include Lakeraven::EHR::SmartAuthentication
  before_action :authenticate_smart_token!

  def show
    render json: { ok: true, scopes: current_token.scopes.to_s }
  end

  def patient_read
    return unless authorize_scope!("patient/Patient.read")
    render json: { ok: true }
  end

  def patient_write
    return unless authorize_scope!("patient/Patient.write")
    render json: { ok: true }
  end

  def patient_context
    return unless authorize_patient_context!(params[:identifier])
    render json: { ok: true, identifier: params[:identifier] }
  end
end

class Lakeraven::EHR::SmartAuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.routes.disable_clear_and_finalize = true
    Rails.application.routes.draw do
      get "/_smart_auth_test/show", to: "smart_auth_test#show"
      get "/_smart_auth_test/patient_read", to: "smart_auth_test#patient_read"
      get "/_smart_auth_test/patient_write", to: "smart_auth_test#patient_write"
      get "/_smart_auth_test/patient_context/:identifier", to: "smart_auth_test#patient_context"
    end

    @client = Doorkeeper::Application.create!(
      name: "test client",
      redirect_uri: "https://example.test/callback",
      scopes: "openid patient/Patient.read"
    )
  end

  teardown do
    Rails.application.reload_routes!
    Rails.application.routes.disable_clear_and_finalize = false
  end

  def issue_token(scopes:)
    Doorkeeper::AccessToken.create!(
      application: @client,
      resource_owner_id: 1,
      scopes: scopes,
      expires_in: 3600
    )
  end

  def bearer(token)
    # With hash_token_secrets enabled, the plaintext token is only
    # available via #plaintext_token immediately after create.
    plaintext = token.plaintext_token || token.token
    { "Authorization" => "Bearer #{plaintext}" }
  end

  test "missing Authorization header returns 401 OperationOutcome with code login" do
    get "/_smart_auth_test/show"
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "login", body["issue"].first["code"]
  end

  test "Authorization header without Bearer scheme returns 401" do
    get "/_smart_auth_test/show", headers: { "Authorization" => "Basic abc" }
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "login", body["issue"].first["code"]
  end

  test "invalid Bearer token returns 401 OperationOutcome with code login" do
    get "/_smart_auth_test/show", headers: { "Authorization" => "Bearer not-a-real-token" }
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "login", body["issue"].first["code"]
  end

  test "valid Bearer token grants access" do
    token = issue_token(scopes: "openid patient/Patient.read")
    get "/_smart_auth_test/show", headers: bearer(token)
    assert_response :ok
    body = JSON.parse(response.body)
    assert_includes body["scopes"], "patient/Patient.read"
  end

  test "expired token returns 401" do
    token = Doorkeeper::AccessToken.create!(
      application: @client,
      resource_owner_id: 1,
      scopes: "openid patient/Patient.read",
      expires_in: 3600,
      created_at: 2.hours.ago
    )
    get "/_smart_auth_test/show", headers: bearer(token)
    assert_response :unauthorized
  end

  test "revoked token returns 401" do
    token = issue_token(scopes: "openid patient/Patient.read")
    token.revoke
    get "/_smart_auth_test/show", headers: bearer(token)
    assert_response :unauthorized
  end

  test "authorize_scope! grants access when token has the required scope" do
    token = issue_token(scopes: "patient/Patient.read")
    get "/_smart_auth_test/patient_read", headers: bearer(token)
    assert_response :ok
  end

  test "authorize_scope! returns 403 OperationOutcome forbidden when scope is missing" do
    token = issue_token(scopes: "openid")
    get "/_smart_auth_test/patient_read", headers: bearer(token)
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "forbidden", body["issue"].first["code"]
  end

  test "authorize_scope! accepts a wildcard patient/*.read scope" do
    token = issue_token(scopes: "patient/*.read")
    get "/_smart_auth_test/patient_read", headers: bearer(token)
    assert_response :ok
  end

  test "authorize_scope! accepts system/*.read for any patient resource" do
    token = issue_token(scopes: "system/*.read")
    get "/_smart_auth_test/patient_read", headers: bearer(token)
    assert_response :ok
  end

  test "patient/*.read does NOT satisfy a write requirement" do
    # Regression: a read-only wildcard token must not silently pass a
    # write authorization check.
    token = issue_token(scopes: "patient/*.read")
    get "/_smart_auth_test/patient_write", headers: bearer(token)
    assert_response :forbidden
  end

  test "system/*.read does NOT satisfy a write requirement" do
    token = issue_token(scopes: "system/*.read")
    get "/_smart_auth_test/patient_write", headers: bearer(token)
    assert_response :forbidden
  end

  test "patient/*.write satisfies a patient/Patient.write requirement" do
    token = issue_token(scopes: "patient/*.write")
    get "/_smart_auth_test/patient_write", headers: bearer(token)
    assert_response :ok
  end

  test "patient/*.* satisfies any patient permission" do
    token = issue_token(scopes: "patient/*.*")
    get "/_smart_auth_test/patient_write", headers: bearer(token)
    assert_response :ok
  end

  # -- authorize_patient_context! --------------------------------------------

  def issue_patient_token(patient_identifier:, scopes: "patient/Patient.read")
    Doorkeeper::AccessToken.create!(
      application: @client,
      resource_owner_id: patient_identifier,
      scopes: scopes,
      expires_in: 3600
    )
  end

  test "authorize_patient_context! grants access when token patient matches request" do
    token = issue_patient_token(patient_identifier: "pt_01H8X")
    get "/_smart_auth_test/patient_context/pt_01H8X", headers: bearer(token)
    assert_response :ok
  end

  test "authorize_patient_context! returns 403 forbidden on patient mismatch" do
    token = issue_patient_token(patient_identifier: "pt_01H8X")
    get "/_smart_auth_test/patient_context/pt_other", headers: bearer(token)
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "forbidden", body["issue"].first["code"]
  end

  test "authorize_patient_context! bypasses the check for system tokens" do
    token = issue_token(scopes: "system/Patient.read")
    get "/_smart_auth_test/patient_context/pt_01H8X", headers: bearer(token)
    assert_response :ok
  end

  test "authorize_patient_context! bypasses the check for user tokens" do
    token = issue_token(scopes: "user/Patient.read")
    get "/_smart_auth_test/patient_context/pt_01H8X", headers: bearer(token)
    assert_response :ok
  end

  test "authorize_patient_context! returns 403 when patient scope token has no bound patient" do
    token = issue_patient_token(patient_identifier: "")
    get "/_smart_auth_test/patient_context/pt_01H8X", headers: bearer(token)
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "forbidden", body["issue"].first["code"]
  end
end
