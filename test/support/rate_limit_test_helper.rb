# frozen_string_literal: true

require "base64"
require "digest"

# Shared helpers for lakeraven-ehr#498 rate-limit defect tests.
module RateLimitTestHelper
  ALLOWLIST_PATH = File.expand_path("rate_limit_route_allowlist.yml", __dir__).freeze
  RATE_LIMIT_CONSTANT = "Lakeraven::EHR::RateLimit"

  # Controllers (or credential-accepting actions) that must never appear on the allowlist.
  NEVER_ALLOWLISTED_CONTROLLERS = %w[
    lakeraven/ehr/charts
    lakeraven/ehr/dashboards
    lakeraven/ehr/patient_contexts
    lakeraven/ehr/screenings
    lakeraven/ehr/practitioners
    lakeraven/ehr/organizations
    lakeraven/ehr/locations
    lakeraven/ehr/patients
    lakeraven/ehr/allergy_intolerances
    lakeraven/ehr/conditions
    lakeraven/ehr/medication_requests
    lakeraven/ehr/observations
    lakeraven/ehr/encounters
    lakeraven/ehr/service_requests
    lakeraven/ehr/immunizations
    lakeraven/ehr/procedures
    lakeraven/ehr/consents
    lakeraven/ehr/audit_events
    lakeraven/ehr/value_sets
    lakeraven/ehr/measure_reports
    lakeraven/ehr/measures
    lakeraven/ehr/ccda_imports
    lakeraven/ehr/coverage_eligibility_requests
    lakeraven/ehr/transitions_of_care
    lakeraven/ehr/exports
    lakeraven/ehr/export_files
    lakeraven/ehr/backend_services
    lakeraven/ehr/allergies
    lakeraven/ehr/chart_searches
    lakeraven/ehr/registration/patients
    lakeraven/ehr/registration/demographics
    lakeraven/ehr/registration/addresses
    lakeraven/ehr/registration/contacts
    lakeraven/ehr/registration/languages
    lakeraven/ehr/registration/other_names
    lakeraven/ehr/registration/eligibilities
    lakeraven/ehr/registration/coverages
    lakeraven/ehr/scheduling/clinics
    lakeraven/ehr/scheduling/open_times
    lakeraven/ehr/scheduling/hours
    lakeraven/ehr/scheduling/patient_appointments
    lakeraven/ehr/scheduling/appointments
    lakeraven/ehr/scheduling/quick_registrations
    lakeraven/ehr/scheduling/cancellations
    lakeraven/ehr/scheduling/checkins
    lakeraven/ehr/scheduling/reschedules
    lakeraven/ehr/scheduling/appointment_details
    lakeraven/ehr/scheduling/walk_ins
    lakeraven/ehr/scheduling/checkouts
    lakeraven/ehr/scheduling/no_shows
  ].freeze

  NEVER_ALLOWLISTED_ROUTE_KEYS = %w[
    lakeraven/ehr/sessions#create
  ].freeze

  module_function

  def engine_route_keys
    Lakeraven::EHR::Engine.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next if controller.blank? || action.blank?

      "#{controller}##{action}"
    end.uniq.sort
  end

  def reviewed_allowlist_keys
    data = YAML.load_file(ALLOWLIST_PATH)
    Array(data.fetch("routes")).map(&:to_s).uniq.sort
  end

  def allowlist_phi_violations
    reviewed_allowlist_keys.filter_map do |key|
      controller, _action = key.split("#", 2)
      if NEVER_ALLOWLISTED_ROUTE_KEYS.include?(key)
        key
      elsif NEVER_ALLOWLISTED_CONTROLLERS.include?(controller)
        key
      end
    end
  end

  def uncovered_routes(extra: [])
    routes = (engine_route_keys + Array(extra)).map(&:to_s).uniq.sort
    allowed = reviewed_allowlist_keys
    throttled = throttled_route_keys_if_present
    routes - allowed - throttled
  end

  def rate_limit_failure!(message)
    raise Minitest::Assertion, message
  end

  def rate_limit_module!
    unless Lakeraven::EHR.const_defined?(:RateLimit, false)
      rate_limit_failure! "#{RATE_LIMIT_CONSTANT} must be implemented for lakeraven-ehr#498 " \
                          "(register throttled routes and expose .throttled_route_keys)"
    end
    Lakeraven::EHR::RateLimit
  end

  def throttled_route_keys_if_present
    return [] unless Lakeraven::EHR.const_defined?(:RateLimit, false)

    mod = Lakeraven::EHR::RateLimit
    unless mod.respond_to?(:throttled_route_keys)
      rate_limit_failure! "#{RATE_LIMIT_CONSTANT} must implement .throttled_route_keys for the convention test (#498)"
    end
    Array(mod.throttled_route_keys).map(&:to_s).uniq.sort
  end

  def throttled_route_keys
    rate_limit_module!
    throttled_route_keys_if_present
  end

  def with_test_rate_limit(max_requests:, window: 1.minute)
    mod = rate_limit_module!
    unless mod.respond_to?(:configure_for_test!)
      rate_limit_failure! "#{RATE_LIMIT_CONSTANT} must expose .configure_for_test!(max_requests:, window:) " \
                          "so integration tests can use a small limit (#498)"
    end
    mod.configure_for_test!(max_requests: max_requests, window: window)
    yield
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  def normalized_throttle_response(response)
    headers = response.headers.to_h.transform_keys { |k| k.to_s.downcase }
    headers = headers.except("date", "x-request-id", "x-runtime")
    {
      status: response.status,
      headers: headers.sort.to_h,
      body: response.body.b
    }
  end

  def assert_positive_retry_after!(response)
    value = response.headers["Retry-After"].to_s
    assert_match(/\A\d+\z/, value, "Retry-After must be an integer number of seconds")
    assert_operator value.to_i, :>, 0
  end

  def assert_throttle_audit_event!(pattern: /throttl/i)
    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "expected a throttle event as an AuditEvent row (#498)"
    assert_match pattern, event.outcome_desc.to_s,
                 "expected the audit row to describe rate limiting (#498)"
  end

  def rate_limit_key_count!
    mod = rate_limit_module!
    unless mod.respond_to?(:key_count)
      rate_limit_failure! "#{RATE_LIMIT_CONSTANT} must expose .key_count so memory bounds are testable (#498)"
    end
    mod.key_count
  end

  # Call before configuring limits when .bucket_count is not implemented.
  def assert_rate_limit_storage_countable!(mod)
    return if mod.respond_to?(:bucket_count)

    unless mod.respond_to?(:key_count)
      rate_limit_failure! "#{RATE_LIMIT_CONSTANT} must expose .bucket_count or .key_count (#498)"
    end
    mod.configure_for_test!(max_requests: 100, window: 1.minute, max_keys: 10_000)
    mod.permit?(identity: "bearer:storage-probe-a", ip: "127.0.0.1")
    baseline = mod.key_count
    mod.permit?(identity: "bearer:storage-probe-b", ip: "127.0.0.1")
    unless mod.key_count > baseline
      rate_limit_failure! "#{RATE_LIMIT_CONSTANT} must expose .bucket_count or make .key_count " \
                           "count every stored bucket (#498)"
    end
    mod.reset! if mod.respond_to?(:reset!)
  end

  def rate_limit_stored_bucket_count(mod)
    return mod.bucket_count if mod.respond_to?(:bucket_count)

    unless mod.respond_to?(:key_count)
      rate_limit_failure! "#{RATE_LIMIT_CONSTANT} must expose .bucket_count or .key_count (#498)"
    end
    mod.key_count
  end

  FAIL_CLOSED_NEWCOMER_IP = "198.51.100.50"

  # Fills the rate-limit table to max_keys: nine saturated bearer pairs plus one nil-identity
  # hit on FAIL_CLOSED_NEWCOMER_IP (1 of max_requests). Every stored identity bucket is at its
  # limit, so a new identity on that IP can only be refused (fail-closed), not evict-in.
  def build_fail_closed_saturated_table!(mod, max_requests: 2, max_keys: 19, window: 10.minutes)
    mod.configure_for_test!(max_requests: max_requests, window: window, max_keys: max_keys)
    (1..9).each do |n|
      ip = "198.51.100.#{n}"
      max_requests.times do
        assert mod.permit?(identity: "bearer:full-#{n}", ip: ip),
               "saturate bearer:full-#{n} on #{ip} (#498 H1)"
      end
    end
    assert mod.permit?(identity: nil, ip: FAIL_CLOSED_NEWCOMER_IP),
           "newcomer IP must sit at 1 of #{max_requests} before the probe (#498 H1)"
    assert_equal max_keys, mod.bucket_count,
                 "table must be full (#498 H1); bucket_count=#{mod.bucket_count}"
    FAIL_CLOSED_NEWCOMER_IP
  end

  # Same capacity as build_fail_closed_saturated_table!, but bearer:full-9 has only one hit so it
  # may be evicted when a new identity arrives on FAIL_CLOSED_NEWCOMER_IP.
  def build_fail_closed_table_with_light_identity!(mod, max_requests: 2, max_keys: 19, window: 10.minutes)
    mod.configure_for_test!(max_requests: max_requests, window: window, max_keys: max_keys)
    (1..8).each do |n|
      ip = "198.51.100.#{n}"
      max_requests.times do
        assert mod.permit?(identity: "bearer:full-#{n}", ip: ip),
               "saturate bearer:full-#{n} on #{ip} (#498 H1)"
      end
    end
    assert mod.permit?(identity: "bearer:full-9", ip: "198.51.100.9"),
           "bearer:full-9 must stay under its identity limit (#498 H1)"
    assert mod.permit?(identity: nil, ip: FAIL_CLOSED_NEWCOMER_IP),
           "fill table to max_keys with newcomer IP at 1 of #{max_requests} (#498 H1)"
    assert_equal max_keys, mod.bucket_count,
                 "table must be full (#498 H1); bucket_count=#{mod.bucket_count}"
    FAIL_CLOSED_NEWCOMER_IP
  end

  def monotonic_seconds
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def integration_request_env(remote_addr:, x_forwarded_for: nil)
    env = { "REMOTE_ADDR" => remote_addr.to_s }
    env["HTTP_X_FORWARDED_FOR"] = x_forwarded_for if x_forwarded_for
    env
  end

  def reset_rate_limit_declarations!
    return unless Lakeraven::EHR.const_defined?(:RateLimit, false)

    mod = Lakeraven::EHR::RateLimit
    mod.remove_instance_variable(:@declared_keys) if mod.instance_variable_defined?(:@declared_keys)
    mod.throttled_route_keys if mod.respond_to?(:throttled_route_keys)
  end

  # Maps controller#action to a minimal integration request (path, verb, params, headers).
  def sample_request_for_route_key(route_key)
    controller, action = route_key.split("#", 2)
    route = Lakeraven::EHR::Engine.routes.routes.find do |r|
      r.defaults[:controller] == controller && r.defaults[:action] == action.to_s
    end
    rate_limit_failure! "no engine route for #{route_key} (#498)" unless route

    verb = route.verb.to_s.delete_prefix("^").delete_suffix("$").downcase
    verb = "get" if verb.blank?
    path = route.path.spec.to_s
    path = path.gsub("(.:format)", "").gsub("(.format)", "")
    path = path.gsub(/:\w+/, "1")
    path = path.gsub(/\(\?:\/([^)]+)\)\?/, "")
    path = "/lakeraven-ehr#{path}"
    path = path.gsub("//", "/")

    params = sample_params_for(controller, action)
    headers = sample_headers_for(controller, action)
    { verb: verb, path: path, params: params, headers: headers }
  end

  def sample_params_for(controller, action)
    case controller
    when "lakeraven/ehr/sessions"
      { username: "probe-user", password: "wrong" }
    when "lakeraven/ehr/backend_services"
      {
        grant_type: "client_credentials",
        client_id: "rate-limit-probe",
        client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        client_assertion: "probe.jwt",
        scope: "system/*.read"
      }
    when "lakeraven/ehr/patients"
      action == "create" ? { resourceType: "Patient", name: [ { family: "Probe" } ] } : { name: "Probe" }
    when "lakeraven/ehr/patient_contexts"
      {}
    when "lakeraven/ehr/ccda_imports", "lakeraven/ehr/transitions_of_care"
      { resourceType: "Bundle", type: "document" }
    when "lakeraven/ehr/coverage_eligibility_requests"
      { resourceType: "CoverageEligibilityRequest", status: "active" }
    when "lakeraven/ehr/exports"
      { patient_dfn: "1" }
    when "lakeraven/ehr/measures"
      { file: "probe.ndjson" }
    when "lakeraven/ehr/screenings"
      { instrument: "phq-9" }
    when "lakeraven/ehr/chart_searches"
      { query: "probe" }
    when %r{\Alakeraven/ehr/registration/}
      registration_sample_params(action)
    when %r{\Alakeraven/ehr/scheduling/}
      scheduling_sample_params(controller, action)
    when "lakeraven/ehr/allergies"
      { dfn: "1" }
    else
      {}
    end
  end

  def registration_sample_params(action)
    case action
    when "index", "create", "confirm", "new"
      { dfn: "1", query: "probe" }
    when "show", "edit", "update"
      { dfn: "1" }
    else
      { dfn: "1" }
    end
  end

  def scheduling_sample_params(controller, action)
    base = { resource_id: "1", appointment_id: "1", dfn: "1", id: "1" }
    case controller
    when "lakeraven/ehr/scheduling/clinics"
      action == "show" || action == "week" ? { id: "1" } : base
    else
      base
    end
  end

  def sample_headers_for(controller, _action)
    return {} if %w[lakeraven/ehr/sessions lakeraven/ehr/backend_services].include?(controller)

    { "Authorization" => "Bearer rate-limit-probe-token" }
  end

  def issue_integration_request!(verb:, path:, params: {}, headers: {}, env: {})
    case verb
    when "get", "head"
      public_send(verb, path, params: params, headers: headers, env: env)
    when "post", "put", "patch", "delete"
      public_send(verb, path, params: params, headers: headers, env: env)
    else
      get path, params: params, headers: headers, env: env
    end
  end

  def rate_limit_controller_source_paths
    root = Lakeraven::EHR::Engine.root.join("app/controllers/lakeraven/ehr")
    Dir.glob(root.join("**/*_controller.rb")).reject do |path|
      base = File.basename(path)
      base == "application_controller.rb" || base == "base_controller.rb"
    end
  end

  def controller_path_for_source(path)
    root = Lakeraven::EHR::Engine.root.join("app/controllers/lakeraven/ehr")
    relative = Pathname.new(path).relative_path_from(root).to_s.delete_suffix(".rb")
    "lakeraven/ehr/#{relative.delete_suffix("_controller")}"
  end

  def rate_limit_macro_counts_by_controller
    counts = Hash.new(0)
    rate_limit_controller_source_paths.each do |path|
      source = File.read(path)
      counts[controller_path_for_source(path)] = source.scan(/rate_limit\s+only:/).length
    end
    counts
  end

  def controllers_declaring_login_throttle
    found = []
    rate_limit_controller_source_paths.each do |path|
      source = File.read(path)
      next unless source.match?(/rate_limit\s+only:.*login_throttle:\s*true/)

      found << controller_path_for_source(path)
    end
    found.sort
  end

  def unsigned_jwt(payload)
    header = Base64.urlsafe_encode64('{"alg":"none"}', padding: false)
    body = Base64.urlsafe_encode64(payload.to_json, padding: false)
    "#{header}.#{body}.sig"
  end

  def with_secret_key_base(value)
    original = Rails.application.secret_key_base
    Rails.application.config.secret_key_base = value
    yield
  ensure
    Rails.application.config.secret_key_base = original
  end

  def assert_not_sha256_or_prefix!(identifier, secret)
    digest = Digest::SHA256.hexdigest(secret.to_s)
    refute_equal digest, identifier.to_s,
                 "throttle audit must not store unsalted SHA-256 of the identity (#498 F4)"
    (1..digest.length).each do |len|
      next unless identifier.to_s.length == len

      refute_equal digest[0, len], identifier.to_s,
                   "throttle audit must not store a prefix of unsalted SHA-256 (#498 F4)"
    end
  end

  def without_login_throttle_enforcement
    throttle = Lakeraven::EHR::LoginThrottle
    original_throttled = throttle.method(:throttled?)
    original_record = throttle.method(:record_failure)
    throttle.define_singleton_method(:throttled?) { |*_args| false }
    throttle.define_singleton_method(:record_failure) { |*_args| nil }
    yield
  ensure
    throttle.define_singleton_method(:throttled?, original_throttled)
    throttle.define_singleton_method(:record_failure, original_record)
  end

  def rate_limit_declarations_for(controller_path)
    relative = controller_path.delete_prefix("lakeraven/ehr/")
    path = Lakeraven::EHR::Engine.root.join("app/controllers/lakeraven/ehr/#{relative}_controller.rb")
    return [] unless File.exist?(path)

    File.read(path).scan(/rate_limit\s+only:\s*([^,\n]+)/).flat_map do |capture|
      actions = capture.first
      if actions.include?("%i[")
        actions[/\%i\[(.*?)\]/, 1].split(/\s+/).map(&:to_sym)
      elsif actions.include?("%w[")
        actions[/\%w\[(.*?)\]/, 1].split(/\s+/).map(&:to_sym)
      else
        [ actions.strip.delete_prefix(":").to_sym ]
      end
    end
  end
end
