# frozen_string_literal: true

# `Lakeraven::EHR::ClientJwks.resolver` is PROCESS-GLOBAL. The JWKS transport
# scenarios install a fake mapping and, without a restore, every later
# scenario resolves names through that stub — the order dependence this
# suite already fixed for token_endpoint_url.
#
# Snapshot before each scenario, restore after. Unconditional, so a scenario
# that raises still restores.
Before do
  @__client_jwks_resolver_before = Lakeraven::EHR::ClientJwks.resolver
end

After do
  Lakeraven::EHR::ClientJwks.resolver = @__client_jwks_resolver_before
end
