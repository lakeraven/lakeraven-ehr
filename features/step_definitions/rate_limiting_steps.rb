# frozen_string_literal: true

# Rate limiting acceptance spec (#498) — Kimball features/rate_limiting.feature

require "active_support/testing/time_helpers"

module RateLimitingSteps
  LOGIN_PATH = "/lakeraven-ehr/login"
  PATIENT_SEARCH_PATH = "/lakeraven-ehr/Patient"

  ACCOUNTS = {
    "provider1" => %w[testprovider test123],
    "provider2" => %w[testnurse test123]
  }.freeze

  SYNTHETIC_UNLISTED_ROUTE = "lakeraven/ehr/rate_limit_convention_synthetic_probe#index"

  module_function

  def account_credentials(name)
    user, pass = ACCOUNTS.fetch(name)
    [ user, pass ]
  end
end

Before("@security") do
  Lakeraven::EHR::LoginThrottle.reset!
  Lakeraven::EHR::AuditEvent.delete_all
  if Lakeraven::EHR.const_defined?(:RateLimit, false) && Lakeraven::EHR::RateLimit.respond_to?(:reset!)
    Lakeraven::EHR::RateLimit.reset!
  end
  @rate_limit_client_ip = "198.51.100.10"
  @rate_limit_last_response = nil
  @rate_limit_uncovered_routes = nil
end

Before("@pending") do |scenario|
  next unless scenario.location.file.end_with?("rate_limiting.feature")

  skip_this_scenario("lakeraven-ehr#471 public tokenized consent/pre-visit links not implemented")
end

def rate_limit_post_login(username:, password:, remote_addr: @rate_limit_client_ip)
  post RateLimitingSteps::LOGIN_PATH,
       { username: username, password: password },
       { "REMOTE_ADDR" => remote_addr }
  @rate_limit_last_response = last_response
end

def ensure_fhir_patient_read_token!
  return if @fhir_headers&.dig("Authorization").present? &&
            @smart_token&.scopes.to_s.include?("system/Patient.read")

  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all

  @oauth_app = Doorkeeper::Application.create!(
    name: "rate-limit-cucumber",
    redirect_uri: "https://example.test/callback",
    scopes: "system/Patient.read system/*.read",
    confidential: true
  )
  @smart_token = Doorkeeper::AccessToken.create!(
    application: @oauth_app,
    scopes: "system/Patient.read system/*.read",
    expires_in: 3600
  )
  token = @smart_token.plaintext_token || @smart_token.token
  @fhir_headers = {
    "Accept" => "application/fhir+json",
    "Authorization" => "Bearer #{token}"
  }
end

def patient_search_request!
  ensure_fhir_patient_read_token!
  @fhir_headers.each { |k, v| header k, v }
  get "#{RateLimitingSteps::PATIENT_SEARCH_PATH}?name=Anderson"
  @rate_limit_last_response = last_response
end

# --- Authentication ----------------------------------------------------------

When("I submit {int} failed sign-ins for account {string} from one address") do |count, account|
  username, password = RateLimitingSteps.account_credentials(account)
  count.times { rate_limit_post_login(username: username, password: "#{password}-wrong") }
end

When("I submit {int} failed sign-ins for account {string} from {int} different addresses") do |count, account, addrs|
  username, = RateLimitingSteps.account_credentials(account)
  count.times do |i|
    ip = "198.51.100.#{i + 1}"
    rate_limit_post_login(username: username, password: "wrongwrong", remote_addr: ip)
  end
end

Given("account {string} is throttled after repeated failures") do |account|
  username, = RateLimitingSteps.account_credentials(account)
  attempts = Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS
  # Spread failures across addresses so the shared clinic NAT is not IP-throttled
  # when another account signs in from @rate_limit_client_ip (#498).
  attempts.times do |i|
    rate_limit_post_login(username: username, password: "wrongwrong", remote_addr: "198.51.101.#{i + 1}")
  end
  rate_limit_post_login(username: username, password: "wrongwrong", remote_addr: "198.51.101.99")
  assert_equal 429, @rate_limit_last_response.status
end

When("the throttle window elapses") do
  travel_seconds = @rate_limit_last_response.headers["Retry-After"].to_i + 1
  @rate_limit_time_anchor ||= Time.current
  @rate_limit_time_anchor += travel_seconds
  travel_to @rate_limit_time_anchor
end

When("account {string} signs in from the same address") do |account|
  username, password = RateLimitingSteps.account_credentials(account)
  rate_limit_post_login(username: username, password: password)
end

Then("the next sign-in attempt should be throttled") do
  username, = RateLimitingSteps.account_credentials("provider1")
  rate_limit_post_login(username: username, password: "wrongwrong")
  assert_equal 429, @rate_limit_last_response.status
end

Then("the next sign-in attempt for {string} should be throttled") do |account|
  username, = RateLimitingSteps.account_credentials(account)
  rate_limit_post_login(username: username, password: "wrongwrong")
  assert_equal 429, @rate_limit_last_response.status
end

Then("a correct sign-in for {string} should succeed") do |account|
  username, password = RateLimitingSteps.account_credentials(account)
  rate_limit_post_login(username: username, password: password)
  assert_includes [ 302, 303 ], @rate_limit_last_response.status,
                  "expected redirect after successful sign-in, got #{@rate_limit_last_response.status}"
end

Then("the sign-in should succeed") do
  assert_includes [ 302, 303 ], @rate_limit_last_response.status,
                  "expected redirect after successful sign-in, got #{@rate_limit_last_response.status}"
end

Then('the response should include a {string} header') do |header_name|
  key = @rate_limit_last_response.headers.keys.find { |k| k.casecmp?(header_name) }
  assert key, "expected #{header_name} header on last response"
  assert @rate_limit_last_response.headers[key].present?, "#{header_name} must be present"
end

# --- Clinical read surface ---------------------------------------------------

When("I issue {int} patient searches within the throttle window") do |count|
  ensure_fhir_patient_read_token!
  @rate_limit_mod = RateLimitTestHelper.rate_limit_module!
  @rate_limit_mod.configure_for_test!(max_requests: count, window: 1.minute)
  count.times do
    patient_search_request!
    assert_equal 200, @rate_limit_last_response.status,
                 "search #{count} should succeed under the configured limit (#498)"
  end
end

Given("my session has been throttled for patient search") do
  ensure_fhir_patient_read_token!
  Lakeraven::EHR::AuditEvent.delete_all
  @rate_limit_mod = RateLimitTestHelper.rate_limit_module!
  @rate_limit_mod.configure_for_test!(max_requests: 1, window: 1.minute)
  patient_search_request!
  patient_search_request!
  assert_equal 429, @rate_limit_last_response.status
end

When("I issue another patient search") do
  patient_search_request!
end

Then("the next patient search should be throttled") do
  patient_search_request!
  assert_equal 429, @rate_limit_last_response.status
end

# --- Route convention coverage -----------------------------------------------

When("the rate-limit convention check runs") do
  extra = @synthetic_uncovered_route ? [ @synthetic_uncovered_route ] : []
  @rate_limit_uncovered_routes = RateLimitTestHelper.uncovered_routes(extra: extra)
end

Then("every route should be either throttled or on the reviewed allowlist") do
  uncovered = @rate_limit_uncovered_routes || RateLimitTestHelper.uncovered_routes
  assert_empty uncovered,
               "each route must be throttled or on test/support/rate_limit_route_allowlist.yml (#498):\n" \
               "#{uncovered.join("\n")}"
end

Given("a route exists that is neither throttled nor allowlisted") do
  @synthetic_uncovered_route = RateLimitingSteps::SYNTHETIC_UNLISTED_ROUTE
end

Then("the check should fail") do
  refute_empty @rate_limit_uncovered_routes,
               "expected the convention check to find at least one uncovered route (#498)"
end

Then("the failure should name the route") do
  assert_includes @rate_limit_uncovered_routes, @synthetic_uncovered_route,
                  "failure must name the synthetic uncovered route (#498)"
end

World(ActiveSupport::Testing::TimeHelpers)

After("@security") do
  travel_back
  if Lakeraven::EHR.const_defined?(:RateLimit, false) && Lakeraven::EHR::RateLimit.respond_to?(:reset!)
    Lakeraven::EHR::RateLimit.reset!
  end
  Lakeraven::EHR::LoginThrottle.reset!
end
