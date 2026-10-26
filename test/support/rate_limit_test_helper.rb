# frozen_string_literal: true

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
end
