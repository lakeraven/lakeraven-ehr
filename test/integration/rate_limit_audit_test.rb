# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: throttle audit rows are deduplicated per key per window,
# failures to write audit still return 429, and identities are digested.
class RateLimitAuditTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include RateLimitTestHelper

  setup do
    setup_smart_auth(scopes: "system/Patient.read system/*.read")
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "one throttle audit row per key per window during a flood of refusals" do
    raw_token = @headers["Authorization"].to_s.delete_prefix("Bearer ")

    with_test_rate_limit(max_requests: 0, window: 5.minutes) do
      Lakeraven::EHR::AuditEvent.delete_all
      50.times do
        get "/lakeraven-ehr/Patient/1", headers: @headers,
            env: integration_request_env(remote_addr: "198.51.100.60")
        assert_response :too_many_requests
      end

      throttle_rows = Lakeraven::EHR::AuditEvent.where(outcome_desc: Lakeraven::EHR::RateLimit::AUDIT_DESCRIPTION)
      assert_operator throttle_rows.count, :<=, 3,
                      "flood of refusals for one key must write at most one audit row per limb/key (#498); " \
                      "saw #{throttle_rows.count}"
      throttle_rows.each do |row|
        refute_includes row.to_json, raw_token,
                        "audit row must not store the raw bearer token (#498)"
      end
    end
  end

  test "audit persistence failure still returns 429 with Retry-After" do
    with_test_rate_limit(max_requests: 0, window: 5.minutes) do
      model = Lakeraven::EHR::AuditEvent
      original = model.method(:create!)
      model.define_singleton_method(:create!) { |*| raise ActiveRecord::StatementInvalid, "audit down" }
      begin
        begin
          get "/lakeraven-ehr/Patient/1", headers: @headers,
              env: integration_request_env(remote_addr: "198.51.100.61")
        rescue ActiveRecord::StatementInvalid => e
          flunk "throttle must rescue audit failures and still return 429 (#498): #{e.message}"
        end

        assert_response :too_many_requests,
                         "throttle must not become 500 when audit insert fails (#498); got #{response.status}"
        assert_positive_retry_after!(response)
      ensure
        model.define_singleton_method(:create!, original)
      end
    end
  end

  test "throttle audit carries a digest of identity, not the raw access code" do
    LOGIN = "/lakeraven-ehr/login"
    access_code = "clinic-access-probe"
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::AuditEvent.delete_all

    with_test_rate_limit(max_requests: 0, window: 5.minutes) do
      post LOGIN,
           params: { username: access_code, password: "wrong" },
           env: integration_request_env(remote_addr: "198.51.100.62")

      assert_response :too_many_requests,
                       "sessions#create must be rate limited by RateLimit (#498)"

      event = Lakeraven::EHR::AuditEvent.order(:id).last
      refute_nil event
      refute_includes event.to_json, access_code,
                      "throttle audit must not store the raw access code (#498)"
      identifier = event.agent_who_identifier
      refute_nil identifier, "throttle audit must carry an identity digest (#498 F4)"
      assert_not_sha256_or_prefix!(identifier, access_code)
    end
  ensure
    Lakeraven::EHR::LoginThrottle.reset!
  end

  test "F4 throttle audit identity digest is HMAC keyed on secret_key_base" do
    access_code = "clinic-access-hmac-probe"
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::AuditEvent.delete_all

    identifiers = []
    %w[deployment-alpha-secret deployment-beta-secret].each do |secret|
      with_secret_key_base(secret) do
        with_test_rate_limit(max_requests: 0, window: 5.minutes) do
          post "/lakeraven-ehr/login",
               params: { username: access_code, password: "wrong" },
               env: integration_request_env(remote_addr: "198.51.100.63")
          assert_response :too_many_requests
          event = Lakeraven::EHR::AuditEvent.order(:id).last
          refute_nil event
          identifiers << event.agent_who_identifier
        end
      end
      Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR::RateLimit.respond_to?(:reset!)
    end

    assert_equal 2, identifiers.compact.size
    refute_equal identifiers[0], identifiers[1],
                 "the same access code must digest differently per deployment secret (#498 F4)"
  ensure
    Lakeraven::EHR::LoginThrottle.reset!
  end
end
