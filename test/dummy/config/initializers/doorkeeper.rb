# frozen_string_literal: true

Doorkeeper.configure do
  orm :active_record

  # API-only — no resource owner authentication flow needed.
  # SMART tokens are issued externally; the engine only validates them.
  resource_owner_authenticator do
    nil
  end

  # SMART App Launch v1 scopes (ONC §170.315(g)(10)). Host apps mounting
  # the engine should configure the same scope set; see the engine README.
  default_scopes "system/*.read"
  optional_scopes "openid", "fhirUser",
                  "launch", "launch/patient", "offline_access",
                  "patient/*.read", "patient/*.*",
                  "patient/Patient.read", "patient/AllergyIntolerance.read",
                  "patient/Condition.read", "patient/MedicationRequest.read",
                  "patient/Observation.read", "patient/Immunization.read",
                  "patient/Procedure.read", "patient/Encounter.read",
                  "user/*.read", "user/*.*",
                  "user/Patient.read", "user/AllergyIntolerance.read",
                  "user/Condition.read", "user/MedicationRequest.read",
                  "user/Observation.read", "user/Practitioner.read",
                  "system/*.read", "system/*.write", "system/*.*"

  # Allow all grant flows for testing
  grant_flows %w[authorization_code client_credentials refresh_token]

  # Issue refresh tokens so offline_access / permission-offline launches
  # can renew access without a fresh launch handshake.
  use_refresh_token

  # Skip client authentication for token introspection in tests
  allow_token_introspection do
    true
  end
end
