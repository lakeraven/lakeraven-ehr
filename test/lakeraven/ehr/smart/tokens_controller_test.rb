# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::Smart::TokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    Lakeraven::EHR::LaunchContext.delete_all
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::AccessGrant.delete_all
    Doorkeeper::Application.delete_all

    @client = Doorkeeper::Application.create!(
      name: "test client",
      redirect_uri: "https://example.test/callback",
      scopes: "system/Patient.read launch/patient",
      confidential: true
    )
    @client_secret = @client.plaintext_secret || @client.secret
  end

  def post_token(params = {}, tenant: "tnt_test")
    headers = tenant ? { "X-Tenant-Identifier" => tenant } : {}
    post "/lakeraven-ehr/oauth/token",
         params: {
           grant_type: "client_credentials",
           client_id: @client.uid,
           client_secret: @client_secret,
           scope: "system/Patient.read"
         }.merge(params),
         headers: headers
  end

  def mint_for_client(**overrides)
    Lakeraven::EHR::LaunchContext.mint(
      tenant_identifier: "tnt_test",
      oauth_application_uid: @client.uid,
      patient_identifier: "pt_01H8X",
      **overrides
    )
  end

  test "client_credentials without launch returns a normal token response" do
    post_token
    assert_response :ok
    body = JSON.parse(response.body)
    assert body["access_token"].present?
    refute body.key?("patient"), "expected no patient field without launch context"
  end

  test "client_credentials with a valid launch token embeds patient in the response" do
    ctx = mint_for_client
    post_token({ launch: ctx.launch_token })
    assert_response :ok
    body = JSON.parse(response.body)
    assert body["access_token"].present?
    assert_equal "pt_01H8X", body["patient"]
  end

  test "client_credentials with an unknown launch token returns the token without patient" do
    post_token({ launch: "lc_does_not_exist" })
    assert_response :ok
    body = JSON.parse(response.body)
    assert body["access_token"].present?
    refute body.key?("patient")
  end

  test "client_credentials with an expired launch token returns the token without patient" do
    ctx = mint_for_client(ttl: 1.minute)
    travel_to(Time.current + 5.minutes) do
      post_token({ launch: ctx.launch_token })
      assert_response :ok
      body = JSON.parse(response.body)
      refute body.key?("patient")
    end
  end

  test "client_credentials with launch context including encounter embeds both" do
    ctx = mint_for_client(encounter_identifier: "enc_01H8Y")
    post_token({ launch: ctx.launch_token })
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "pt_01H8X", body["patient"]
    assert_equal "enc_01H8Y", body["encounter"]
  end

  test "token_type is preserved as Bearer when launch is embedded" do
    ctx = mint_for_client
    post_token({ launch: ctx.launch_token })
    body = JSON.parse(response.body)
    assert_equal "Bearer", body["token_type"]
  end

  test "request without launch still passes other token fields through" do
    post_token
    body = JSON.parse(response.body)
    assert body["expires_in"].present?
    assert_equal "Bearer", body["token_type"]
    assert body["scope"].include?("system/Patient.read")
  end

  test "launch token from another tenant does not embed patient context" do
    # Cross-tenant: a launch minted in tnt_other can't bleed its
    # patient into a token issued on tnt_test's surface.
    ctx = Lakeraven::EHR::LaunchContext.mint(
      tenant_identifier: "tnt_other",
      oauth_application_uid: @client.uid,
      patient_identifier: "pt_foreign"
    )
    post_token({ launch: ctx.launch_token }, tenant: "tnt_test")
    assert_response :ok
    body = JSON.parse(response.body)
    assert body["access_token"].present?
    refute body.key?("patient"), "expected no patient field on cross-tenant launch"
  end

  test "launch token bound to a different client does not embed patient context" do
    # Cross-client: a launch minted for app B is useless when redeemed
    # by app A even if both belong to the same tenant.
    other_client = Doorkeeper::Application.create!(
      name: "other client",
      redirect_uri: "https://example.test/callback",
      scopes: "system/Patient.read launch/patient",
      confidential: true
    )
    ctx = Lakeraven::EHR::LaunchContext.mint(
      tenant_identifier: "tnt_test",
      oauth_application_uid: other_client.uid,
      patient_identifier: "pt_foreign"
    )
    post_token({ launch: ctx.launch_token })
    assert_response :ok
    body = JSON.parse(response.body)
    assert body["access_token"].present?
    refute body.key?("patient"), "expected no patient field on cross-client launch"
  end

  test "launch token is single-use: a replay returns the token without patient context" do
    ctx = mint_for_client

    post_token({ launch: ctx.launch_token })
    first_body = JSON.parse(response.body)
    assert_equal "pt_01H8X", first_body["patient"]

    post_token({ launch: ctx.launch_token })
    second_body = JSON.parse(response.body)
    assert second_body["access_token"].present?
    refute second_body.key?("patient"), "second redemption must not return patient context"
  end

  test "missing tenant header drops the launch context but still issues a token" do
    ctx = mint_for_client
    post_token({ launch: ctx.launch_token }, tenant: nil)
    assert_response :ok
    body = JSON.parse(response.body)
    assert body["access_token"].present?
    refute body.key?("patient")
    # Single-use guarantee: with no tenant, we don't even attempt
    # the resolve, so the context stays unconsumed and a follow-up
    # request with the right tenant header still gets the patient.
    assert_nil ctx.reload.consumed_at
  end
end
