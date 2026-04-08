Feature: SMART on FHIR authentication
  As a SMART-on-FHIR client
  I need a discovery endpoint and OAuth 2.0 token machinery
  So that I can obtain a Bearer token to call FHIR endpoints

  This feature lands the OAuth 2.0 surface — discovery, authorize,
  token, revoke, introspect — and the Bearer-token validation
  concern that FHIR controllers will use. Bearer enforcement on
  /Patient/:identifier itself comes in a focused follow-up so this
  PR doesn't have to update the existing us_core_patient_api scenarios.

  Scenario: SMART discovery document is publicly accessible
    When I GET the SMART discovery document
    Then the response status is 200
    And the discovery document advertises an authorization_endpoint
    And the discovery document advertises a token_endpoint
    And the discovery document lists S256 as a code_challenge_method
    And the discovery document lists "patient/Patient.read" in scopes_supported
    And the discovery document lists "launch-standalone" in capabilities

  Scenario: OAuth token endpoint is mounted under the engine
    When I POST to the OAuth token endpoint with no parameters
    Then the response status is 400 or 401
    And the response body mentions an OAuth error

  Scenario: OAuth authorize endpoint is mounted under the engine
    When I GET the OAuth authorize endpoint with no parameters
    Then the response is not a 404

  Scenario: A registered confidential client can mint a system token via client_credentials
    Given a confidential OAuth client is registered with scopes "system/Patient.read"
    When I POST to the OAuth token endpoint with grant_type "client_credentials" and the client credentials
    Then the response status is 200
    And the response body includes an access_token
    And the response body includes a token_type of "Bearer"
