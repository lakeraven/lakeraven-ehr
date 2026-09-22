@partner_auth
Feature: SMART Backend Services auth for server-to-server FHIR clients
  As a FHIR server serving server-to-server clients (partner source-system profile, section 2)
  The token endpoint should issue tokens only for JWT assertions verified against
  the client's published JWKS, and each credential should be bound to one
  organization and demonstrably unable to read another organization's patients.

  Background:
    Given the system is configured for FHIR API access

  # --- Conformance checklist item 1:
  # "Backend services token obtained with a signed JWT assertion against a published JWKS"

  Scenario: Token issued for a JWT assertion signed by the client's published JWKS key
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read system/Observation.read"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read system/Observation.read"
    Then the response status should be 200
    And the response JSON should include "access_token"
    And the token response should grant scope "system/Patient.read system/Observation.read"
    And the token response should expire in at most 300 seconds

  Scenario: Assertion signed by a key outside the published JWKS is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with an assertion signed by a different key
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: Expired assertion is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with an expired signed assertion
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: Assertion with the wrong audience is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with a signed assertion for audience "https://elsewhere.example.test/token"
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: A replayed assertion is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read"
    Then the response status should be 200
    When the client replays the same assertion
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: Granted scopes never exceed the client's registration
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read system/Observation.read"
    Then the response status should be 200
    And the token response should grant scope "system/Patient.read"

  Scenario: A request for only unregistered scopes is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with a valid signed assertion and scope "system/DiagnosticReport.read"
    Then the response status should be 400
    And the response JSON should include error "invalid_scope"

  Scenario: A client registered without a JWKS cannot obtain a token
    Given a backend client "Example Org A Connector" is registered without a JWKS and scopes "system/Patient.read"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read"
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: A client with no organization binding cannot obtain a system token
    Given a backend client "Example Unbound Connector" is registered with a published JWKS but no organization binding, with scopes "system/Patient.read"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read"
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  # Refusing issuance is not enough: a token whose application carries no
  # organization binding (registered before binding became mandatory, minted
  # through another flow, or whose binding was later blanked — the column is
  # nullable for interactive apps) must ALSO be denied at the authorization
  # layer. Fail closed: an org-bound-absent system credential reads NOTHING.
  # (Independent security review finding on the fail-open nil-org path.)

  Scenario: An assertion with no exp claim is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with a signed assertion that has no exp claim
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: An assertion expiring just past the five-minute cap is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with a signed assertion that expires 315 seconds from now
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: An assertion with a six-minute lifetime is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with a signed assertion that expires 360 seconds from now
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: An unsigned alg=none assertion is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with an unsigned alg=none assertion
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  Scenario: An HMAC assertion keyed with the published RSA public key is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    When the client requests a token with an HMAC assertion keyed with the published RSA public key
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  # --- JWKS transport (SSRF / key-substitution hardening): keys are fetched
  # only over HTTPS from public addresses, and a failed fetch is never cached.

  Scenario: A plain-HTTP JWKS URL cannot be registered
    Then registering a backend client with jwks_uri "http://client.example.test/jwks.json" is rejected

  Scenario: A private-address JWKS URL cannot be registered
    Then registering a backend client with jwks_uri "https://192.168.0.10/jwks.json" is rejected

  Scenario: A loopback JWKS URL cannot be registered
    Then registering a backend client with jwks_uri "https://127.0.0.1/jwks.json" is rejected

  @webmock
  Scenario: A JWKS host that resolves to a private address is not fetched
    Given a backend client whose registered JWKS host resolves to "10.0.0.5"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read"
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  # Special-use ranges that are not loopback/private/link-local but are still
  # not publicly routable client infrastructure: carrier-grade NAT
  # (100.64.0.0/10), benchmarking (198.18.0.0/15), multicast (224.0.0.0/4,
  # ff00::/8), and reserved/broadcast (240.0.0.0/4). (Independent security
  # review finding: these fell through the earlier public-address check.)

  Scenario: A carrier-grade NAT JWKS URL cannot be registered
    Then registering a backend client with jwks_uri "https://100.64.0.5/jwks.json" is rejected

  Scenario: A benchmarking-range JWKS URL cannot be registered
    Then registering a backend client with jwks_uri "https://198.18.0.5/jwks.json" is rejected

  Scenario: A multicast JWKS URL cannot be registered
    Then registering a backend client with jwks_uri "https://224.0.0.1/jwks.json" is rejected

  @webmock
  Scenario: A JWKS host that resolves to a carrier-grade NAT address is not fetched
    Given a backend client whose registered JWKS host resolves to "100.64.0.5"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read"
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  @webmock
  Scenario: A JWKS host that resolves to a benchmarking-range address is not fetched
    Given a backend client whose registered JWKS host resolves to "198.18.0.5"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read"
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  @webmock
  Scenario: A JWKS host that resolves to a multicast address is not fetched
    Given a backend client whose registered JWKS host resolves to "224.0.0.1"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read"
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

  @webmock
  # --- Audience: the expected aud is the configured token endpoint URL, not
  # whatever host the request arrived on (proxy mismatch / cross-host replay).

  Scenario: With a configured token endpoint URL, that audience is accepted
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    And the server is configured with token endpoint URL "https://ehr.example.test/lakeraven-ehr/oauth/token"
    When the client requests a token with a signed assertion for audience "https://ehr.example.test/lakeraven-ehr/oauth/token"
    Then the response status should be 200
    And the response JSON should include "access_token"

  Scenario: With a configured token endpoint URL, the request-host audience is rejected
    Given a backend client "Example Org A Connector" is registered with a published JWKS and scopes "system/Patient.read"
    And the server is configured with token endpoint URL "https://ehr.example.test/lakeraven-ehr/oauth/token"
    When the client requests a token with a valid signed assertion and scope "system/Patient.read"
    Then the response status should be 401
    And the response JSON should include error "invalid_client"

