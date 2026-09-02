# frozen_string_literal: true

# Clean OAuth state between Vardana auth conformance scenarios.
Before("@vardana_auth") do
  Doorkeeper::AccessToken.delete_all if defined?(Doorkeeper::AccessToken)
  Doorkeeper::Application.delete_all if defined?(Doorkeeper::Application)
  if defined?(Lakeraven::EHR::AssertionReplayGuard)
    Lakeraven::EHR::AssertionReplayGuard.reset!
  end
  @fhir_headers = nil
  @response_json = nil
end
