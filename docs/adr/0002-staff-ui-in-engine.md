# ADR 0002: Clinical staff UI lives in the engine, not the SaaS host

**Status:** Accepted
**Date:** 2026-05-24

## Context

The legacy `rpms_redux` monolith bundled clinical workflows (charting, encounters, dashboards, cases, tasks), administrative concerns (account management, billing, subscription), and the Rails plumbing into one app. The decomposition split this into:

- `lakeraven-ehr` — Rails engine (clinical logic, gateways, FHIR API)
- `lakeraven-ehr-saas` — host application built on a SaaS framework that mounts the engine
- supporting gems (`rpms-rpc`, `lakeraven-fhir`)

When porting the redux staff UI (`home`, `dashboard`, `cases`, `tasks`, `service_requests`, `encounters`, `patients`, `reconciliations`, `public_health_dashboards`), there is a placement choice: does the controller + view layer live in the engine or in the SaaS host?

A prior framing said "staff UI lives in the SaaS shell." That was incorrect for this product. The customer-facing product is "Lakeraven EHR" — and that product IS the engine. The SaaS shell exists to wrap the engine with subscription, billing, multi-tenant onboarding, and marketing-site chrome.

## Decision

**Clinical staff UI controllers, views, helpers, and routes live in `lakeraven-ehr` (the engine).**

The host repository (`lakeraven-ehr-saas`) is **limited to SaaS-framework functions**: account management, authentication, MFA, sessions, subscription/billing, marketing pages, multi-tenant onboarding, password-reset, the public landing page. It mounts the engine; it does not duplicate clinical UI.

**Guiding principle: let Jumpstart Pro do what it does best; keep as much core clinical logic in the engine as possible.** The host is built on Jumpstart Pro — accounts, authentication, MFA/2FA, sessions, teams/multi-tenancy, billing, subscriptions, and admin are framework concerns it already solves; the engine must not reimplement them. The engine owns clinical logic and its UI. Every placement question resolves to a single test: **is this a Jumpstart-Pro framework concern (→ host) or clinical (→ engine)?** In particular, **MFA is out of scope for the engine** — Jumpstart Pro provides 2FA, and the engine must not carry its own.

Specific port placements:

| Surface | Repo |
|---|---|
| `home`, `dashboard`, `cases`, `tasks`, `service_requests`, `encounters`, `patients`, `reconciliations`, `public_health_dashboards`, `pwa` | `lakeraven-ehr` (engine) |
| Subscription, billing, marketing site, account onboarding, password reset | `lakeraven-ehr-saas` (host) |
| Authentication, MFA/2FA, sessions, admin, audit-report UI | `lakeraven-ehr-saas` (host) — Jumpstart Pro concerns; **out of scope for the engine**. See ADR 0001 in that repo. |

Engine ships routes mounted by the host. Views live under `app/views/lakeraven/ehr/`. The engine + decorator + repository pattern (existing convention) is the canonical seam between models, gateways, and view-rendering.

## Consequences

### Positive

- The engine becomes a complete product, not a partial library. A second host (e.g. an open-source self-host deployment) can mount the engine and get the full clinical UI without porting controllers.
- Clinical conventions (policies, decorators, view helpers, FHIR serialization) stay co-located with their models and services in the engine — easier to keep consistent than across two repos.
- The SaaS host stays focused on the cross-tenant concerns it's good at (subscription tiers, billing, multi-tenancy), without dragging in clinical UI maintenance.

### Negative

- The engine grows substantially in surface area (controllers, views, JS, CSS). Engine tests must include integration coverage that previously lived in redux's app/.
- Some shared chrome (header, navigation, theme) must work both standalone in the engine (for tests / engine dummy app) and inside the host. Need a clear layout convention.
- Host-app developers need to know the engine layer well; they can't treat it as an opaque dependency.

### Alternatives considered

- **Staff UI in `lakeraven-ehr-saas`.** Rejected. Makes the engine a partial library that requires a specific host to be useful. Couples clinical UI maintenance to SaaS-framework upgrades. Splits clinical-domain expertise across two repos.
- **Separate `lakeraven-ehr-ui` engine.** Rejected as premature decomposition. There is no second host on the horizon that would benefit from an isolated UI engine, and splitting controllers from models adds friction without clear value.
- **No host; engine includes its own SaaS layer.** Rejected. SaaS-framework functions (subscriptions, marketing) belong in the framework that's good at them, not in the clinical engine.

## Consequences for the redux port

Existing host-app port issues (#48–55) that targeted "host app" are retargeted at the engine. Each becomes a per-domain port PR into `lakeraven-ehr/app/controllers/lakeraven/ehr/`.

The patient portal is an exception — it lives in `lakeraven-self` (a separate consumer-DPI host), with its own ADR. Authentication, MFA, sessions, and admin are Jumpstart-Pro concerns in the host (above), with their own ADR in `lakeraven-ehr-saas`.

**Migration debt (as of this ADR):** the engine currently carries auth/session/MFA and admin UI that predate this decision — e.g. `SessionsController`, `WebController`, `authentication.feature`, `mfa_authentication.feature`, `admin/*` views. Per the guiding principle these belong in the host on Jumpstart Pro and should migrate out of the engine. The permanent VistA sign-on (the real replacement for any interim engine login) must be built on the host's Jumpstart-Pro authentication with a VistA strategy, **not** a hand-rolled engine `SessionsController`.

## References

- Issue #326 (this ADR closes the strategic-decision portion of)
- ADR 0001 in `lakeraven-ehr-saas` (admin/MFA placement)
- Issue #324 (rpms_redux port audit umbrella)
- Issue #327, #325 (sibling placement decisions)
