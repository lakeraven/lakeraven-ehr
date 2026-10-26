# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: limits are keyed by IP and by identity (bearer token).
class RateLimitIdentityTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include RateLimitTestHelper

  setup do
    Lakeraven::EHR::AuditEvent.delete_all
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "one bearer token from several addresses is throttled by identity" do
    setup_smart_auth(scopes: "system/Patient.read system/*.read")
    limit = 2
    ips = %w[10.0.0.1 10.0.0.2 10.0.0.3]

    with_test_rate_limit(max_requests: limit) do
      ips.each do |ip|
        get "/lakeraven-ehr/Patient/1", headers: @headers, env: { "REMOTE_ADDR" => ip }
        assert_response :success, "request from #{ip} should succeed under the limit"
      end

      get "/lakeraven-ehr/Patient/1", headers: @headers, env: { "REMOTE_ADDR" => "10.0.0.99" }

      assert_response :too_many_requests,
                       "the same token must be throttled across addresses (#498)"
      assert_positive_retry_after!(response)
    end
  end

  test "many bearer tokens from one address are throttled by IP" do
    limit = 2
    ip = "192.0.2.50"
    tokens = 3.times.map { mint_token }

    with_test_rate_limit(max_requests: limit) do
      tokens.each do |headers|
        get "/lakeraven-ehr/Patient/1", headers: headers, env: { "REMOTE_ADDR" => ip }
        assert_response :success
      end

      get "/lakeraven-ehr/Patient/1", headers: mint_token, env: { "REMOTE_ADDR" => ip }

      assert_response :too_many_requests,
                       "one address must be throttled across tokens (#498)"
      assert_positive_retry_after!(response)
    end
  end

  private

  def mint_token
    app = Doorkeeper::Application.create!(
      name: "rl-#{SecureRandom.hex(3)}", redirect_uri: "https://example.test/cb",
      scopes: "system/Patient.read system/*.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/Patient.read system/*.read", expires_in: 3600
    )
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end
end
