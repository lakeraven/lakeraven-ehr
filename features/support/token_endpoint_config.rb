# frozen_string_literal: true

# `Lakeraven::EHR.configuration.token_endpoint_url` is PROCESS-GLOBAL. A
# scenario that sets it (the backend-services audience scenarios do) leaves it
# set for every scenario that runs afterwards, and the next assertion built
# against a different audience is then rejected with "Assertion audience does
# not match the token endpoint".
#
# That is not hypothetical: it broke features/onc/backend_services_auth.feature
# only in a full-suite run, and only depending on file order — the scenario
# passed in isolation. Order-dependent state is worse than a plain failure,
# because it shows up as an unrelated test being flaky.
#
# Snapshot before each scenario, restore after. Unconditional, so a scenario
# that raises still restores.
Before do
  @__token_endpoint_url_before = Lakeraven::EHR.configuration.token_endpoint_url
end

After do
  Lakeraven::EHR.configuration.token_endpoint_url = @__token_endpoint_url_before
end
