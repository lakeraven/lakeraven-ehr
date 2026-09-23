# frozen_string_literal: true

# Steps for features/session_scope_policy.feature.
#
# Keys are named by their RPMS strings (the values ORWU USERKEYS returns), not
# by our internal symbols, so these steps run the real chain:
#   RPMS key string -> SecurityKeys.symbolize -> SessionScopePolicy.
# Symbolizing here rather than passing symbols in is deliberate: an unmodelled
# site key has to be dropped by the registry for the deny-by-default scenarios
# to mean anything.

# What the ENFORCEMENT side treats as a write, taken from
# SmartAuthentication#can_write? — `scope_permits?(resource_type, %w[write c *])`.
# Kept identical on purpose: a step that recognises a different set of write
# forms than the gate does would pass while an actual write scope shipped. An
# earlier version matched /\.(write|c|cud)\z/ — inventing `.cud`, which the gate
# does not honour, and missing `.*`, which it does.
WRITE_SCOPE_SUFFIXES = %w[write c *].freeze
WRITE_SCOPE_PATTERN = /\.(#{WRITE_SCOPE_SUFFIXES.map { |s| Regexp.escape(s) }.join("|")})\z/

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

# Bypasses SecurityKeys.symbolize deliberately. Every symbol the registry can
# produce is currently modelled in KEY_SCOPES, so the policy's OWN
# deny-by-default guard is unreachable through the RPMS-string path — the
# registry drops the unknown key first. Handing the policy a symbol it does not
# model is the only way to pin that guard, and it is a real caller contract:
# scopes_for takes symbols, and nothing in its signature promises they came from
# the registry.
Given("the resolved security keys include {string}, which the policy does not model") do |symbol|
  @security_keys = [ symbol.to_sym ]
end

Given("the resolved security keys are {string} plus {string}, which the policy does not model") do |modelled, unmodelled|
  @security_keys = [ modelled.to_sym, unmodelled.to_sym ]
end

When("their session scopes are resolved") do
  @granted_scopes = Lakeraven::EHR::SessionScopePolicy.scopes_for(
    security_keys: @security_keys
  )
end

# The exact-set assertion. Every key is pinned with this rather than with
# positive spot-checks: a sampled assertion cannot tell a widened grant from the
# intended one, which is how prc_tech, eligibility_verify and dental all stayed
# green while silently reaching further.
Then("the granted scopes should be exactly:") do |table|
  expected = table.raw.flatten.map(&:strip).sort
  assert_equal expected, @granted_scopes.sort,
    "Scope set mismatch for #{@security_keys.inspect}\n" \
    "  unexpected: #{(@granted_scopes - expected).inspect}\n" \
    "  missing:    #{(expected - @granted_scopes).inspect}"
end

Then("the granted scopes should be exactly what {string} alone grants") do |symbol|
  baseline = Lakeraven::EHR::SessionScopePolicy.scopes_for(security_keys: [ symbol.to_sym ])
  assert_equal baseline.sort, @granted_scopes.sort
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

Then("every granted scope should begin with {string}") do |prefix|
  offenders = @granted_scopes.reject { |s| s.start_with?(prefix) }
  assert_empty offenders,
    "Expected every scope to begin with #{prefix.inspect}, but found #{offenders.inspect}"
end

# `user/*.read` would hand every resource type to any key that carried it, so no
# entry in the table may name the wildcard resource. Distinct from the write
# check above, which is about the ACTION half of the scope.
Then("no granted scope should name the wildcard resource type") do
  offenders = @granted_scopes.select { |s| s.split("/").last.to_s.start_with?("*") }
  assert_empty offenders,
    "Expected no wildcard resource scopes, found #{offenders.inspect}"
end

# Table drift: the registry resolves RPMS strings to symbols, the policy maps
# symbols to scopes, and nothing links them. A key in one and not the other
# fails silently in production — denied privilege, or privilege unreachable.
Then("every key in the RPMS security key registry should have a scope policy entry") do
  registry = RpmsRpc::SecurityKeys::REGISTRY.keys
  policy = Lakeraven::EHR::SessionScopePolicy::KEY_SCOPES.keys
  missing = registry - policy
  assert_empty missing,
    "RPMS keys with no scope policy entry (they resolve at sign-on and are then " \
    "silently denied): #{missing.inspect}"
end

Then("every scope policy entry should correspond to an RPMS security key") do
  registry = RpmsRpc::SecurityKeys::REGISTRY.keys
  policy = Lakeraven::EHR::SessionScopePolicy::KEY_SCOPES.keys
  orphaned = policy - registry
  assert_empty orphaned,
    "Scope policy entries with no RPMS registry key (unreachable from a real " \
    "sign-on, but still counted in all_scopes): #{orphaned.inspect}"
end
