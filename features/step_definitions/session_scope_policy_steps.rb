# frozen_string_literal: true

# Steps for features/session_scope_policy.feature.
#
# Keys are named by their RPMS strings (the values ORWU USERKEYS returns), not
# by our internal symbols, so these steps run the real chain:
#   RPMS key string -> SecurityKeys.symbolize -> SessionScopePolicy.
# Symbolizing here rather than passing symbols in is deliberate: an unmodelled
# site key has to be dropped by the registry for the deny-by-default scenarios
# to mean anything.

Given("a clinician with no RPMS security keys") do
  @security_keys = []
end

Given("a clinician whose RPMS security keys are {string}") do |key_list|
  raw = key_list.split(",").map(&:strip).reject(&:empty?)
  @security_keys = RpmsRpc::SecurityKeys.symbolize(raw)
end

Given("a clinician holding every security key this engine models") do
  @security_keys = RpmsRpc::SecurityKeys::REGISTRY.keys
end

When("their session scopes are resolved") do
  @granted_scopes = Lakeraven::EHR::SessionScopePolicy.scopes_for(
    security_keys: @security_keys
  )
end

Then("the granted scopes should be empty") do
  assert_empty @granted_scopes,
    "Expected no scopes for keys #{@security_keys.inspect}, got #{@granted_scopes.inspect}"
end

Then("the granted scopes should not be empty") do
  refute_empty @granted_scopes, "Expected some scopes but got none"
end

Then("the granted scopes should include:") do |table|
  table.raw.flatten.map(&:strip).each do |scope|
    assert_includes @granted_scopes, scope,
      "Expected #{scope.inspect} in #{@granted_scopes.inspect}"
  end
end

Then("the granted scopes should not include:") do |table|
  table.raw.flatten.map(&:strip).each do |scope|
    refute_includes @granted_scopes, scope,
      "Expected #{scope.inspect} NOT to be granted, but it was"
  end
end

Then("no scope should permit writing") do
  writes = @granted_scopes.grep(/\.(write|c|cud)\z/)
  assert_empty writes, "Expected no write scopes, got #{writes.inspect}"
end

Then("the only write scope granted should be {string}") do |scope|
  writes = @granted_scopes.grep(/\.(write|c|cud)\z/)
  assert_equal [ scope ], writes
end

Then("every granted scope should begin with {string}") do |prefix|
  offenders = @granted_scopes.reject { |s| s.start_with?(prefix) }
  assert_empty offenders,
    "Expected every scope to begin with #{prefix.inspect}, but found #{offenders.inspect}"
end

# Bypasses SecurityKeys.symbolize deliberately. Every symbol the registry can
# produce is currently modelled in KEY_SCOPES, so the policy's OWN
# deny-by-default guard is unreachable through the RPMS-string path — the
# registry drops the unknown key first. Handing the policy a symbol it does not
# model is the only way to pin that guard, and it is a real caller contract:
# scopes_for takes symbols, and nothing in its signature promises they came
# from the registry.
Given("the resolved security keys include {string}, which the policy does not model") do |symbol|
  @security_keys = [ symbol.to_sym ]
end

Given("the resolved security keys are {string} plus {string}, which the policy does not model") do |modelled, unmodelled|
  @security_keys = [ modelled.to_sym, unmodelled.to_sym ]
end
