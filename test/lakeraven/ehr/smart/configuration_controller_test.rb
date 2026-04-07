# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::SMART::ConfigurationControllerTest < ActionDispatch::IntegrationTest
  test "GET /.well-known/smart-configuration returns the discovery document" do
    get "/lakeraven-ehr/.well-known/smart-configuration"
    assert_response :ok
    body = JSON.parse(response.body)

    assert_includes body.keys, "authorization_endpoint"
    assert_includes body.keys, "token_endpoint"
    assert_includes body.keys, "capabilities"
    assert_includes body.keys, "scopes_supported"
    assert_includes body.keys, "grant_types_supported"
    assert_includes body.keys, "code_challenge_methods_supported"
  end

  test "advertised endpoint URLs are absolute and point at engine paths" do
    get "/lakeraven-ehr/.well-known/smart-configuration"
    body = JSON.parse(response.body)

    assert_match %r{\Ahttps?://[^/]+/lakeraven-ehr/oauth/authorize\z}, body["authorization_endpoint"]
    assert_match %r{\Ahttps?://[^/]+/lakeraven-ehr/oauth/token\z}, body["token_endpoint"]
  end

  test "S256 is the only PKCE method advertised" do
    get "/lakeraven-ehr/.well-known/smart-configuration"
    body = JSON.parse(response.body)
    assert_equal [ "S256" ], body["code_challenge_methods_supported"]
  end

  test "advertises authorization_code, client_credentials, and refresh_token grant types" do
    get "/lakeraven-ehr/.well-known/smart-configuration"
    body = JSON.parse(response.body)
    assert_equal %w[authorization_code client_credentials refresh_token].sort, body["grant_types_supported"].sort
  end

  test "scopes_supported includes the SMART vocabulary" do
    get "/lakeraven-ehr/.well-known/smart-configuration"
    body = JSON.parse(response.body)
    assert_includes body["scopes_supported"], "openid"
    assert_includes body["scopes_supported"], "launch"
    assert_includes body["scopes_supported"], "launch/patient"
    assert_includes body["scopes_supported"], "patient/Patient.read"
    assert_includes body["scopes_supported"], "user/Patient.read"
    assert_includes body["scopes_supported"], "system/Patient.read"
  end

  test "capabilities include both standalone and EHR launch" do
    get "/lakeraven-ehr/.well-known/smart-configuration"
    body = JSON.parse(response.body)
    assert_includes body["capabilities"], "launch-standalone"
    assert_includes body["capabilities"], "launch-ehr"
  end

  test "discovery endpoint is publicly accessible (no Bearer required)" do
    get "/lakeraven-ehr/.well-known/smart-configuration"
    assert_response :ok
  end
end
