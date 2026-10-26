# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: every engine route is either rate-limited or on a reviewed
# allowlist. The allowlist is the deliverable — a throttle config that stops
# covering new routes is worse than none.
class RateLimitRouteConventionTest < ActiveSupport::TestCase
  include RateLimitTestHelper

  test "every engine route is throttled or on the reviewed allowlist" do
    routes = engine_route_keys
    allowed = reviewed_allowlist_keys
    throttled = throttled_route_keys_if_present

    uncovered = routes - allowed - throttled
    hint = unless Lakeraven::EHR.const_defined?(:RateLimit, false)
      "\nImplement #{RateLimitTestHelper::RATE_LIMIT_CONSTANT} and register throttled routes " \
        "(controller `rate_limit` macro → .throttled_route_keys)."
    end
    assert_empty uncovered,
      "each route must be in test/support/rate_limit_route_allowlist.yml or " \
      "#{RateLimitTestHelper::RATE_LIMIT_CONSTANT}.throttled_route_keys (#498). " \
      "Uncovered:\n#{uncovered.join("\n")}#{hint}"
  end

  test "the reviewed allowlist exempts no patient, clinical, or credential-accepting route" do
    violations = allowlist_phi_violations
    assert_empty violations,
      "test/support/rate_limit_route_allowlist.yml must not allowlist PHI/clinical surfaces or " \
      "credential acceptance (#498). Remove:\n#{violations.join("\n")}"
  end

  test "the reviewed allowlist names no route that no longer exists" do
    routes = engine_route_keys
    allowed = reviewed_allowlist_keys

    stale = allowed - routes
    assert_empty stale,
      "remove stale entries from test/support/rate_limit_route_allowlist.yml (#498):\n#{stale.join("\n")}"
  end

  test "throttled routes are declared on controllers via the rate_limit macro" do
    mod = rate_limit_module!
    unless mod.respond_to?(:throttle_declarations)
      flunk "#{RateLimitTestHelper::RATE_LIMIT_CONSTANT} must expose .throttle_declarations " \
            "so throttling is introspectable from controller declarations (#498)"
    end

    throttled = throttled_route_keys
    declared = Array(mod.throttle_declarations).map(&:to_s)

    undeclared = throttled - declared
    assert_empty undeclared,
      "throttled_route_keys must match controller rate_limit declarations (#498):\n#{undeclared.join("\n")}"

    ghost = declared - throttled
    assert_empty ghost,
      "controller rate_limit declarations must register throttled_route_keys (#498):\n#{ghost.join("\n")}"
  end
end
