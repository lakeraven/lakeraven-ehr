@vardana_auth
Feature: SMART Backend Services auth for server-to-server FHIR clients
  As a FHIR server serving server-to-server clients (Vardana source-system profile, section 2)
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

  Scenario: SMART configuration advertises the configured token endpoint URL
    Given the server is configured with token endpoint URL "https://ehr.example.test/lakeraven-ehr/oauth/token"
    When I request GET "/lakeraven-ehr/.well-known/smart-configuration" without a Bearer token
    Then the response status should be 200
    And the SMART configuration token endpoint should be "https://ehr.example.test/lakeraven-ehr/oauth/token"

  # --- Conformance checklist item 2:
  # "Credential is scoped to one organisation and demonstrably cannot read another's patients"

  Scenario: A credential bound to one organization cannot read another organization's patient
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.read"
    And patient 900001 is managed by organization "rpms-organization-202"
    When I request GET "/lakeraven-ehr/Patient/900001" with the Bearer token
    Then the response status should be 403
    And the response should be a FHIR OperationOutcome with code "forbidden"

  Scenario: The managing organization's own credential reads the same patient
    Given a backend client bound to organization "rpms-organization-202" holds a token with scope "system/*.read"
    And patient 900001 is managed by organization "rpms-organization-202"
    When I request GET "/lakeraven-ehr/Patient/900001" with the Bearer token
    Then the response status should be 200
    And the response should be a FHIR Patient with id "900001"

  Scenario: Cross-organization denial applies to patient-scoped clinical reads
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.read"
    And patient 900001 is managed by organization "rpms-organization-202"
    When I request GET "/lakeraven-ehr/Observation?patient=900001" with the Bearer token
    Then the response status should be 403
    And the response should be a FHIR OperationOutcome with code "forbidden"

  Scenario: A patient with no resolvable managing organization is denied to org-bound credentials
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.read"
    And patient 900001 has no managing organization on record
    When I request GET "/lakeraven-ehr/Patient/900001" with the Bearer token
    Then the response status should be 403
    And the response should be a FHIR OperationOutcome with code "forbidden"

  # Enforcement is on the RESOLVED patient, not the request parameter name —
  # every surface that returns patient data must verify the resolved
  # patient's organization, whatever the parameter is called.

  Scenario: Cross-organization denial applies to the patient chart endpoint
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.read"
    And patient 900001 is managed by organization "rpms-organization-202"
    When I request GET "/lakeraven-ehr/patients/900001.json" with the Bearer token
    Then the response status should be 403

  Scenario: The managing organization's own credential reads the patient chart
    Given a backend client bound to organization "rpms-organization-202" holds a token with scope "system/*.read"
    And patient 900001 is managed by organization "rpms-organization-202"
    When I request GET "/lakeraven-ehr/patients/900001.json" with the Bearer token
    Then the response status should be 200

  Scenario: Cross-organization denial applies to transitions of care documents
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.*"
    And patient 900001 is managed by organization "rpms-organization-202"
    When I request POST "/lakeraven-ehr/transitions_of_care" with patient_dfn "900001" and the Bearer token
    Then the response status should be 403
    And the response should be a FHIR OperationOutcome with code "forbidden"

  Scenario: Cross-organization denial applies to bulk export
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.*"
    And patient 900001 is managed by organization "rpms-organization-202"
    When I request POST "/lakeraven-ehr/exports" with patient_dfn "900001" and the Bearer token
    Then the response status should be 403
    And the response should be a FHIR OperationOutcome with code "forbidden"

  Scenario: An organization-scoped export must name a patient the credential may read
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.*"
    When I request POST "/lakeraven-ehr/exports" without a patient and with the Bearer token
    Then the response status should be 403

  Scenario: An export and its files belong to the client that requested them
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.*"
    And patient 900001 is managed by organization "rpms-organization-101"
    And the client has requested an export for patient 900001
    And a second backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.*"
    When the second client requests the first client's export status
    Then the response status should be 403
    When the second client requests the first client's export file
    Then the response status should be 403

  Scenario: Organization-scoped credentials cannot read the audit log
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.read"
    When I request GET "/lakeraven-ehr/AuditEvent" with the Bearer token
    Then the response status should be 403
    And the response should be a FHIR OperationOutcome with code "forbidden"

  Scenario: Organization-scoped credentials cannot register patients
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.*"
    When I request POST "/lakeraven-ehr/Patient" with a FHIR Patient body and the Bearer token
    Then the response status should be 403

  Scenario: A clinical read for an unresolvable patient is denied even when clinical records exist
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.read"
    And patient 900001 cannot be resolved but clinical records exist for that DFN
    When I request GET "/lakeraven-ehr/Observation?patient=900001" with the Bearer token
    Then the response status should be 403
    And the response should be a FHIR OperationOutcome with code "forbidden"

  Scenario: Patient search returns only the credential's organization's patients
    Given a backend client bound to organization "rpms-organization-101" holds a token with scope "system/*.read"
    And a patient search for "DEMO" would match patients in organizations "rpms-organization-101" and "rpms-organization-202"
    When I request GET "/lakeraven-ehr/Patient?name=DEMO" with the Bearer token
    Then the response status should be 200
    And the Bundle should contain only patients managed by organization "rpms-organization-101"

  # --- Discovery: a client can auto-configure from .well-known/smart-configuration

  Scenario: SMART configuration advertises backend services token auth
    When I request GET "/lakeraven-ehr/.well-known/smart-configuration" without a Bearer token
    Then the response status should be 200
    And the SMART configuration should list grant type "client_credentials"
    And the SMART configuration should list token auth method "private_key_jwt"
    And the SMART configuration should list signing algorithm "RS384"
    And the SMART configuration should list scope "system/Patient.read"
