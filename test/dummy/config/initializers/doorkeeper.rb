# frozen_string_literal: true

Doorkeeper.configure do
  orm :active_record

  # API-only — no resource owner authentication flow needed.
  # SMART tokens are issued externally; the engine only validates them.
  resource_owner_authenticator do
    nil
  end

  # Allow all grant flows for testing
  grant_flows %w[authorization_code client_credentials]

  # Skip client authentication for token introspection in tests
  allow_token_introspection do
    true
  end
end
