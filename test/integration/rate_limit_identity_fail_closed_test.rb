# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498 H1: an identity that cannot be stored must be refused (429), never granted.
class RateLimitIdentityFailClosedTest < ActiveSupport::TestCase
  include RateLimitTestHelper

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "one stored identity does not reopen H1 for a bearer spread across fresh IPs" do
    mod = rate_limit_module!
    max_requests = 3
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: 20)

    max_requests.times do
      assert mod.permit?(identity: "bearer:seed", ip: "192.0.2.1"),
             "seed identity must be granted (#498 H1)"
    end

    18.times do |i|
      assert mod.permit?(identity: nil, ip: "198.51.100.#{i + 1}"),
             "light IP bucket #{i + 1} must be granted (#498 H1)"
    end
    assert_equal 20, mod.bucket_count,
                 "table must be full before victim bearer probes (#498 H1)"

    results = 30.times.map do |i|
      mod.permit?(identity: "bearer:victim", ip: "203.0.113.#{i + 1}")
    end

    assert_equal max_requests, results.count(true),
                 "one stored identity must not reopen H1: expected exactly #{max_requests} grants, got #{results.count(true)} (#498 H1)"
    assert_equal [ true, true, true ], results.first(3),
                 "first #{max_requests} victim probes must grant (#498 H1)"
    assert_operator mod.bucket_count, :<=, 20,
                    "bucket count must stay within max_keys (#498 H1); bucket_count=#{mod.bucket_count}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "a bearer from fresh IPs after the table fills with light IP buckets is granted exactly max_requests times" do
    mod = rate_limit_module!
    max_requests = 3
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: 20)

    20.times do |i|
      assert mod.permit?(identity: nil, ip: "198.51.100.#{i + 1}"),
             "light IP bucket #{i + 1} must be granted (#498 H1)"
    end

    results = 30.times.map do |i|
      mod.permit?(identity: "bearer:fail-closed-probe", ip: "203.0.113.#{i + 1}")
    end

    grants = results.count(true)
    assert_equal max_requests, grants,
                 "identity must fail closed at max_keys: expected exactly #{max_requests} grants, got #{grants} (#498 H1)"
    assert_equal [ true, true, true ] + ([ false ] * 27), results,
                 "first #{max_requests} bearer probes must grant, then refuse (#498 H1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "a bearer spread across many fresh IPs after a large light IP fill grants exactly max_requests times" do
    mod = rate_limit_module!
    max_requests = 3
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: 200)

    200.times do |i|
      assert mod.permit?(identity: nil, ip: "198.51.100.#{i + 1}"),
             "light IP bucket #{i + 1} must be granted (#498 H1)"
    end

    results = 60.times.map do |i|
      mod.permit?(identity: "bearer:fail-closed-large", ip: "203.0.113.#{i + 1}")
    end

    grants = results.count(true)
    assert_equal max_requests, grants,
                 "identity must grant exactly max_requests when the table is full (#498 H1); grants=#{grants}"
    assert_equal [ true, true, true ], results.first(3),
                 "first #{max_requests} bearer probes must grant (#498 H1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "an identity that cannot be stored is refused, not granted" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)

    before = mod.bucket_count
    refute mod.permit?(identity: "bearer:newcomer", ip: newcomer_ip),
           "new identity must be refused when it cannot be stored (#498 H1)"
    assert_equal before, mod.bucket_count, "refusal must not grow stored buckets (#498 H1)"

    assert mod.audit_due?(identity: "bearer:newcomer", ip: newcomer_ip),
           "capacity refusal must be auditable the first time (#498 capacity audit)"
    refute mod.audit_due?(identity: "bearer:newcomer", ip: newcomer_ip),
           "capacity audit must fire at most once per key per window (#498 capacity audit)"
    refute mod.audit_due?(identity: "bearer:newcomer-2", ip: newcomer_ip),
           "a different newcomer must not grow the audit table on the same IP (#498 capacity audit)"

    5.times do
      refute mod.permit?(identity: "bearer:newcomer", ip: newcomer_ip),
             "refused identity must not receive free grants while the table stays saturated (#498 H1)"
    end
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "a refused identity mints no bucket" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)

    before = mod.bucket_count
    mod.permit?(identity: "bearer:newcomer", ip: newcomer_ip)
    assert_equal before, mod.bucket_count,
                 "refused identity must not mint an identity bucket (#498 H1)"

    assert mod.permit?(identity: nil, ip: newcomer_ip),
           "refused newcomer probe must not charge the protected IP bucket (#498 H1)"
    refute mod.permit?(identity: nil, ip: newcomer_ip),
           "newcomer IP must be at its limit after one post-refusal grant (#498 H1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "nil identity is still granted on an IP with budget when identity storage is full" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)

    assert mod.permit?(identity: nil, ip: newcomer_ip),
           "IP limb must still grant when only identity storage is exhausted (#498 H1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "a new identity evicts a light identity rather than being refused" do
    mod = rate_limit_module!
    max_keys = 19
    newcomer_ip = build_fail_closed_table_with_light_identity!(mod, max_keys: max_keys)

    assert_equal max_keys, mod.bucket_count, "fixture must fill the table before the probe (#498 H1)"
    assert mod.permit?(identity: "bearer:newcomer", ip: newcomer_ip),
           "fail-closed must evict an under-limit identity, not refuse every newcomer (#498 H1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end
end

class RateLimitIdentityFailClosedHttpTest < ActionDispatch::IntegrationTest
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

  test "Patient search throttles a bearer spread across fresh IPs after the table fills with light IP buckets" do
    mod = rate_limit_module!
    max_requests = 3
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: 20)

    20.times do |i|
      mod.permit?(identity: nil, ip: "198.51.100.#{i + 1}")
    end

    spec = sample_request_for_route_key("lakeraven/ehr/patients#index")
    headers = mint_fail_closed_http_probe_headers
    statuses = 30.times.map do |i|
      issue_integration_request!(
        verb: spec[:verb],
        path: spec[:path],
        params: spec[:params],
        headers: headers,
        env: integration_request_env(remote_addr: "203.0.113.#{i + 1}")
      )
      response.status
    end

    allowed_statuses = statuses.reject { |status| status == 429 }
    assert_equal max_requests, allowed_statuses.size,
                 "HTTP layer must grant exactly #{max_requests} non-429 responses (#498 H1); allowed=#{allowed_statuses.size}"
    allowed_statuses.each do |status|
      assert_equal 200, status,
                   "allowed probes must succeed, not fail auth (#498 H1); statuses=#{statuses.inspect}"
    end
    throttled = statuses.count(429)
    assert_equal statuses.size - allowed_statuses.size, throttled,
                 "every throttled probe must return 429 (#498 H1); statuses=#{statuses.inspect}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "Patient search returns 429 and one throttle audit when identity storage is full" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)
    spec = sample_request_for_route_key("lakeraven/ehr/patients#index")
    headers = mint_capacity_probe_headers

    Lakeraven::EHR::AuditEvent.delete_all
    assert_difference -> { Lakeraven::EHR::AuditEvent.count }, 1 do
      issue_integration_request!(
        verb: spec[:verb],
        path: spec[:path],
        params: spec[:params],
        headers: headers,
        env: integration_request_env(remote_addr: newcomer_ip)
      )
      assert_response :too_many_requests,
                       "capacity refusal must return 429 (#498 capacity audit); status=#{response.status}"
    end
    assert_throttle_audit_event!(pattern: /throttl/i)
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  def mint_fail_closed_http_probe_headers
    app = Doorkeeper::Application.create!(
      name: "rl-fc-http-#{SecureRandom.hex(3)}", redirect_uri: "https://example.test/cb",
      scopes: "system/Patient.read system/*.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/Patient.read system/*.read", expires_in: 3600
    )
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def mint_capacity_probe_headers
    app = Doorkeeper::Application.create!(
      name: "rl-capacity-#{SecureRandom.hex(3)}", redirect_uri: "https://example.test/cb",
      scopes: "system/Patient.read system/*.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/Patient.read system/*.read", expires_in: 3600
    )
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end
end
