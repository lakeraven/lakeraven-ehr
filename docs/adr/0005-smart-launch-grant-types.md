# ADR 0005: SMART launch grant types

**Status:** Accepted
**Date:** 2026-04-08

## Context

The SMART App Launch specification describes the EHR launch flow as
an OAuth 2.0 authorization code grant with a `launch` parameter
threaded through the authorize → code → token round-trip. The app
authenticates the user interactively, receives an authorization
code, and exchanges that code at the token endpoint for an access
token whose response body carries the patient context.

During the initial port, our test and cucumber coverage for launch
context embedding uses the `client_credentials` grant instead of
`authorization_code`. `client_credentials` lets a confidential
client post to `/oauth/token` with `client_id` + `client_secret`
+ a `launch` parameter, bypassing the browser-driven user consent
flow entirely. The engine's custom tokens controller merges the
bound patient/encounter identifiers into the response the same
way either grant produces.

We chose `client_credentials` for test coverage because the
`authorization_code` flow requires:

1. A browser-style interactive consent UI (or a test driver that
   simulates one)
2. A resource owner authenticator that returns a real user object
3. A prior authorization code minted by the authorize endpoint
4. A PKCE verifier round-trip

None of those are available in the engine's test harness today —
the engine delegates user authentication to the host application
via the `resource_owner_authenticator` configuration hook, and the
host will typically wire it to its own sign-in flow.

## Decision

**`client_credentials` + `launch` is supported as a first-class
transitional mode** for test harnesses, backend-services
integrations, and host applications that want to programmatically
bind patient context without driving a user-agent through the
authorize endpoint. It is **not removed** when production SMART
support matures.

**`authorization_code` + `launch` will also be supported** and is
the spec-correct path for browser-driven SMART EHR launch flows.
It lands in a follow-up PR when the engine grows either its own
minimal user model or a host-app-provided authorize-flow driver.

Both grants resolve the launch token through the same
`LaunchContext.resolve` path: tenant-bound, client-bound, and
single-use. The security properties are identical regardless of
grant type — the difference is whether the app fetches the token
through an interactive user-agent round-trip or directly with
client credentials.

## Rationale

### Why keep `client_credentials` + `launch` permanent

- **Backend services still need launch context.** A SMART Backend
  Services client (e.g. a bulk export pipeline that needs to know
  which patient cohort it's authorized against) legitimately uses
  `client_credentials` and still needs to receive a patient
  identifier in the token response when a host-mediated launch
  has bound one.

- **Test harnesses need a non-interactive path.** Driving an
  authorization-code flow through Rack::Test requires stubbing
  the authorize endpoint's UI, minting grants programmatically,
  and threading PKCE verifiers. That adds test complexity without
  adding coverage — the launch-binding logic doesn't care which
  grant delivered the request.

- **The security story is the same.** Launch token binding
  (tenant, client, single-use) runs inside `LaunchContext.resolve`
  regardless of grant type. A stolen launch token is equally
  useless to an attacker whether they try to redeem it via
  `authorization_code` (needs a valid PKCE verifier and auth code)
  or `client_credentials` (needs the legitimate client's secret).

### Why `authorization_code` + `launch` is still the primary flow

- **SMART App Launch spec conformance.** The spec describes EHR
  launch in terms of authorization code. Conformance test suites
  (ONC Inferno) exercise this path. The engine must support it
  for any site that pursues certification.

- **User consent.** `authorization_code` goes through the
  authorize endpoint, which runs the host's `resource_owner_authenticator`
  and can prompt a user to approve the app's scopes. That's the
  consent moment the spec relies on for HIPAA audit trails.

- **Patient picker replacement.** One of the purposes of EHR
  launch is to skip the patient-picker step that standalone launch
  requires. That only makes sense in a context where the user has
  already authenticated — i.e. through the authorize flow.

## Consequences

### Positive

- Test coverage can exercise the full launch-binding logic without
  plumbing a fake authorization code flow.
- Backend services clients have a clear, supported way to receive
  launch context.
- The security analysis of launch tokens doesn't have to branch on
  grant type — the binding checks are uniform.

### Negative

- Two supported paths to the same behavior can mislead integrators.
  Documentation must make it clear which path SMART apps should
  use (authorization_code) vs which is for backend services and
  tests (client_credentials).
- ONC Inferno conformance still requires the authorization_code
  path. This ADR doesn't ship that — only declares the intent to
  add it alongside the existing client_credentials support.

## References

- SMART App Launch Framework: http://hl7.org/fhir/smart-app-launch/app-launch.html
- SMART Backend Services: http://hl7.org/fhir/smart-app-launch/backend-services.html
- ADR 0002 — PHI tokenization (why LaunchContext stores opaque
  identifiers rather than persisting PHI directly)
