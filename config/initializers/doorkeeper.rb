# frozen_string_literal: true

# Doorkeeper configuration for SMART on FHIR.
#
# Most behavior is host-app territory (which user model to authenticate
# against, what an admin looks like, where unauthenticated users are
# redirected). Those hooks are exposed via Lakeraven::EHR.configure so
# the engine can ship a working default that the host can override.

Doorkeeper.configure do
  orm :active_record

  # The engine's ApplicationController is ActionController::API. Tell
  # Doorkeeper not to expect protect_from_forgery / view rendering /
  # other ActionController::Base helpers.
  api_only

  # The base controller every Doorkeeper route inherits from. Use the
  # engine's ApplicationController so the FHIR error helpers and tenant
  # context are available to OAuth flows that go through the engine.
  base_controller "Lakeraven::EHR::ApplicationController"

  # Resource owner / admin authentication: delegate to host-app hooks.
  # The host-supplied lambda receives `self` (the controller instance)
  # so it can read session, headers, and call redirect_to.
  resource_owner_authenticator do
    Lakeraven::EHR.configuration.resource_owner_authenticator.call(self)
  end

  admin_authenticator do
    Lakeraven::EHR.configuration.admin_authenticator.call(self)
  end

  # Token lifetimes per the SMART App Launch spec.
  authorization_code_expires_in 10.minutes
  access_token_expires_in 1.hour

  # Refresh tokens are required for any client that wants offline_access.
  use_refresh_token

  # Hash tokens and client secrets at rest. Doorkeeper still validates
  # the plaintext value against the hash on every request; the database
  # never sees the secret.
  hash_token_secrets
  hash_application_secrets

  # PKCE is enforced as soon as a client passes code_challenge. The
  # SMART discovery doc advertises S256 as the only method we support
  # so callers know to send PKCE.

  # SSL is required in production for redirect URIs (per SMART spec).
  # Allow non-SSL in dev/test so the test suite doesn't need a TLS
  # endpoint.
  force_ssl_in_redirect_uri false if Rails.env.development? || Rails.env.test?

  grant_flows %w[authorization_code client_credentials refresh_token]

  # SMART on FHIR scopes — see http://hl7.org/fhir/smart-app-launch/scopes-and-launch-context.html
  default_scopes :openid
  optional_scopes(
    :profile,
    :fhirUser,
    :launch,
    :"launch/patient",
    :"launch/practitioner",
    :offline_access,
    :"patient/Patient.read",
    :"patient/Practitioner.read",
    :"patient/Observation.read",
    :"patient/Condition.read",
    :"patient/Encounter.read",
    :"patient/AllergyIntolerance.read",
    :"patient/Immunization.read",
    :"patient/Medication.read",
    :"patient/MedicationRequest.read",
    :"user/Patient.read",
    :"user/Practitioner.read",
    :"user/Patient.write",
    :"system/Patient.read",
    :"system/Practitioner.read",
    :"system/*.read"
  )

  # First-party clients (those registered without scopes or marked
  # confidential) skip the consent screen.
  skip_authorization do |_resource_owner, client|
    client.application.scopes.blank? || client.application.confidential?
  end
end
