# ADR 0009: Every request carries an identity and a scope, respected on the way in, through, and out

**Status:** Proposed
**Date:** 2026-10-06
**Implemented at the RPMS hop by:** ADR 0008 (a broker session is the only way to RPMS)
**Background:** `docs/rpms-client-state-model.md` (what RPMS assumes about its clients)

## Principle

Every request lakeraven-ehr serves is **identified**, and every request runs under a **scope**.
The scope decides three things:

- **in:** what the request may ask for;
- **through:** what every layer it passes through may do on its behalf, down to the RPMS connection;
- **out:** what its response may contain, and where that response may be stored.

Anything that can't be identified or scoped is refused.
Nothing is permitted by default, at any layer.

RPMS can't carry this for us: no RPC names its user (`docs/rpms-client-state-model.md` §1.2).
So the web tier has to establish identity and scope itself, carry them explicitly, and hand them to RPMS through the user's own connection.

## Definitions

**Request context:** one immutable value, built once per request at the edge, holding:

| Field | Meaning | Source |
|---|---|---|
| `principal` | who is asking: a person (DUZ), a client application, or `anonymous` | the authenticator that admitted the request |
| `on_behalf_of` | the person a non-human principal acts for, if any | the token's delegation claim; never a parameter |
| `scopes` | SMART v2 scopes granted (`patient/Observation.rs`, `user/*.cruds`, `system/...`) | the token or browser session, minted server-side |
| `compartment` | the patient the request is confined to, when a scope is patient-bound | the token's launch context |
| `organization` | the tenancy boundary (ADR 0007) | the client registration or session; never a parameter |
| `division` | RPMS `DUZ(2)` | the user's RPMS sign-on and `DIVSET`; never a header |
| `request_id` | correlates this request across logs, audit and RPMS | W3C Trace Context `traceparent`, or generated at the edge |
| `broker_session` | this principal's RPMS connection (ADR 0008), or none | built from the context, never the reverse |

A context is either complete or doesn't exist.
No layer fills in a missing field with a default.

## Decision

### In: identified and scoped at the edge, deny by default

1. **Exactly one authenticator admits a request** and builds its context:
   - the browser session (an HttpOnly, Secure, SameSite cookie);
   - a SMART bearer token (JWT-profile access token, RFC 9068, `aud` = this server);
   - a backend-services client assertion (RFC 7523).

   A request that presents more than one credential is refused, not merged.
2. **The base controllers require a context.** `ApplicationController` and `WebController` both fail closed when none exists.
   A public endpoint (`/.well-known/smart-configuration`, `/metadata`, the sign-in form) declares itself with `public_endpoint!` and gets an `anonymous` context with no scopes.
   No other way to skip authentication exists.
3. **Every action declares what it needs:** a resource type plus an interaction, or a named capability.
   The base controller checks it against `scopes` and `compartment` before the action runs.
   An action that declares nothing is refused.
4. **Identity and scope never come from request input.** DUZ, organization, division and compartment come from the authenticated credential.
   A parameter naming a patient is checked against the compartment, never used to set it.

### Through: the context is passed explicitly, and RPMS checks again

5. **The context is an argument, not ambient state.** Controllers pass it to policies, services and gateways.
   A gateway called without a context raises.
   No thread-local, fiber-local or global holds it (rpms-rpc ADR 0006 rejected the same idea for the client).
6. **The RPMS connection is derived from the context** (ADR 0008).
   A person's request runs on that person's own signed-on connection.
   A non-human principal runs on its named service account's connection, or gets none.
7. **Two independent authorities must both allow.** Our scopes say what this request may do.
   RPMS's keys, menu context and FileMan screens say what this user may do.
   Because the connection is the user's own, RPMS's checks are real, not those of whoever signed in last.
   Our checks narrow RPMS's and never widen them: a scope can't grant what the user's keys deny.
8. **Work that outlives the request carries the context it was granted,** narrowed and recorded:
   - background jobs;
   - Action Cable channels;
   - exports.

   A job stores the principal, its scopes and the request ID it came from, and runs under a service identity acting on behalf of that principal (rpms-client-state-model §2).
   It never runs under no identity.

### Out: the response is checked against the scope before it leaves

9. **An egress check runs on every response with clinical content,** after the action and before rendering:
   - every resource is a type the scope permits to read;
   - every patient-bound resource is inside the compartment, when there is one;
   - the organization matches the context;
   - content filters ran: 42 CFR Part 2 (`Part2EgressFilter`), sensitive-record handling.

   A violation means a gateway or query returned more than it was asked for, so it is a bug, not something to filter quietly.
   The response is refused (500, with an `OperationOutcome` that names no data) and the violation is audited.
   Sections a scope legitimately excludes are left out *before* they are fetched (the chart's per-section scope check), not after.
10. **Responses carrying PHI are never stored where another user can read them.**
    They are sent with `Cache-Control: no-store` and `Vary: Cookie, Authorization`.
    Static assets keep their long cache lifetimes.
11. **Errors don't leak across scope.** A request for a patient outside the compartment gets the same answer as a patient who doesn't exist (404), so the response doesn't confirm the record exists.

### Recorded throughout

12. **One audit row per clinical response** records the context: principal, on-behalf-of, scopes used, compartment, organization, request ID, outcome, and the RPMS CIA session UID from the user's sign-on.
    That links every RPMS-side record to a web request and back.

## Where the code stands (2026-10-06, branch `design/585-broker-session`)

| Rule | Today | Gap |
|---|---|---|
| 1 one authenticator | browser session or SMART token; backend services separate | Close. Check that a request carrying both a cookie and a bearer token is refused |
| 2 deny by default | `ApplicationController` requires a SMART token and a FHIR scope. **`WebController` doesn't:** each subclass opts in with `before_action :require_authentication`. `ChartsController` and `DemoVisitsController` sit outside both bases, with their own checks | Make `WebController` fail closed; give public endpoints a declaration; add a route-inventory test that every route is authenticated or declared public |
| 3 actions declare needs | resource scope derived per controller (`authorize_fhir_scope!`); some per-action skips (`measures#import`) | Make the declaration explicit per action, and refuse an action that declares nothing |
| 4 nothing from input | compartment checks exist (`enforce_declared_compartment!`, `enforce_patient_context!`) | Division and organization still need the same rule; ADR 0007 and #553 |
| 5 explicit context | identity sits in `session[:duz]` and the token; gateways see neither | ADR 0008's `BrokerSession` is the first explicit carrier; extend it to a full request context |
| 6 connection from context | one global `RpmsRpc.client` | ADR 0008 |
| 7 RPMS checks again | not real while the connection is shared | ADR 0008 |
| 8 deferred work | no rule | define with ADR 0008's service identity |
| 9 egress check | only C-CDA egress (`Part2EgressFilter`); `render_bundle` sends what the gateway returned | add the check to `render_bundle` and the chart's bundle |
| 10 no-store | Rails default `private, max-age=0, must-revalidate`; no `no-store` | set it on every authenticated response |
| 11 uniform not-found | not yet checked across controllers | add to the route-inventory test |
| 12 audit context | `AuditableClinicalAccess` records the principal and entity; no request ID, no RPMS session UID | add both |

## Tests that hold the line

- **Route inventory:** every route is either behind a base controller that requires a context or declared public, and the list of public routes is pinned in the test.
- **Every action declares its scope:** a test fails on an action with no declaration.
- **Egress:** a gateway double returns one resource from another patient, or a type outside the scope, and the response is refused and audited.
- **No ambient identity:** a gateway called without a context raises. A web process holds no global broker client (ADR 0008).
- **Two identities:** concurrent users each read under their own DUZ, checked on the RPMS connection (ADR 0008).
- **Cache headers:** every authenticated response carries `no-store`.

## Standards this rests on

- OAuth 2.0 (RFC 6749) with JWT-profile access tokens (RFC 9068) and JWT client assertions (RFC 7523); sender-constrained tokens (DPoP, RFC 9449) as the next step for API clients.
- IETF *OAuth 2.0 for Browser-Based Applications*: the backend-for-frontend pattern for the browser.
- SMART App Launch v2 scopes and launch context; FHIR patient compartments.
- OWASP ASVS V4 (access control): deny by default, enforce on a trusted server layer, least privilege.
- RFC 9111 (HTTP caching): `no-store` for responses that must not be kept.
- W3C Trace Context for request correlation.

## Consequences

- Authorization stops being a gate at the door and becomes a value carried end to end, checked at every hop and once more on the way out.
- Most gaps close by changing the base controllers, `render_bundle`, and ADR 0008's broker seam, not every controller.
- The route-inventory and egress tests make the principle part of the build, so new code that skips it fails CI.
- Some current behavior becomes a refusal (a web screen that forgot to opt in, a response carrying an extra resource), which is the point.
