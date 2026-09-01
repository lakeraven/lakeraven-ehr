# ADR 0004: Clinician EHR UI — near-term VueCentric, long-term web UI over the FHIR surface

**Status:** Proposed
**Date:** 2026-08-14

## Context

An August 2026 audit (#440) confirmed what the codebase shows: **`lakeraven-ehr` is a
headless FHIR/RPC backend with no clinician UI.**

- `config/routes.rb` exposes an ONC (g)(10)-shaped FHIR API — ~26 controllers under
  `app/controllers/lakeraven/ehr/` (Patient, Condition, MedicationRequest, Observation,
  Encounter, Immunization, Procedure, Consent, AuditEvent, ValueSet `$expand`,
  bulk `$export`, Transitions of Care, C-CDA import, …).
- ~35 gateways under `app/gateways/lakeraven/ehr/` translate those reads/writes to RPMS
  RPCs (registration, scheduling, orders, notes, vitals, e-signature, …).
- SMART is already wired: `.well-known/smart-configuration`, `smart/launch` (EHR launch),
  and Backend Services JWT auth (`oauth/token`) on Doorkeeper models.
- `app/views/` contains exactly **one** file — the layout
  (`app/views/layouts/lakeraven/ehr/application.html.erb`). No pages, no clinical screens.

ADR 0002 decided that clinical-staff UI *belongs* in this engine (not the SaaS host).
That placement decision stands — but the UI it places has not been built, and building a
safe, complete clinician UI (orders, notes, med management, scheduling) is a large,
long-horizon effort. Meanwhile clinics need a usable clinical front end **now**.

RPMS ships a native client suite — **VueCentric** (the RPMS EHR GUI), plus BPRM and
other components — that speaks to the same backend over the CIA broker. Our YottaDB
standup already serves the CIA broker (rpms-ops#343); the remaining last-mile is the
shared sign-on gate ("Logins prohibited" at login, identical on keyless-IRIS and YDB).
The engine's parity work (BPRM registration/scheduling digital twin, #412/#413; HTTP
integration-test parity, #416) exercises the same RPC surface VueCentric uses.

## Decision

### Near-term: clinical use runs on native VueCentric

Until a web UI exists, **the supported clinician front end is the native RPMS client
(VueCentric) pointed at the same RPMS instance this engine serves.** We do not build an
interim/partial clinical UI in the engine.

The near-term path:

1. **Sign-on lands.** The shared RPMS sign-on gate on the YDB standup (rpms-ops#343 —
   CIA broker serves connections today; login is blocked at "Logins prohibited") is the
   single blocker. When it lands, VueCentric works against our stack unchanged.
2. **Parity is proven, not assumed.** The BPRM digital-twin and HTTP-parity work
   (#412, #413, #416) is the regression harness that keeps the RPC surface
   VueCentric depends on honest.
3. **The engine stays headless** for this phase: FHIR API + gateways + SMART/OAuth.
   Everything clinical that VueCentric writes flows through the same RPMS globals the
   engine reads, so the FHIR surface stays consistent with native-client activity.

This costs nothing in engine scope and gives clinics the full certified RPMS clinical
workflow (orders, notes, pharmacy, scheduling) on day one.

### Long-term: a modern web EHR UI over the (g)(10) FHIR surface

The end-state clinician UI is a **web application consuming the engine's own FHIR API**
— the same ~26 controllers third parties use — not a parallel stack of view-specific
controllers coupled directly to gateways.

Two placements were weighed:

**(i) UI inside this engine (per ADR 0002).** Rails-rendered (Hotwire) views shipped by
the engine, mounted by any host.

- *For:* engine remains a complete product (ADR 0002's core argument); one repo for
  clinical domain + its UI; host session/auth (Jumpstart Pro) is already solved;
  server-side rendering suits RPC-latency-bound data.
- *Against:* couples UI release cadence to engine releases; tempts controllers to
  bypass the FHIR layer and reach into gateways directly, forking the data path.

**(ii) Separate SPA/host app as a SMART-on-FHIR client.** A standalone app (or a
distinct repo) doing SMART EHR-launch against `smart/launch` + Doorkeeper OAuth,
consuming only the FHIR API.

- *For:* proves the (g)(10) surface is genuinely sufficient (we dogfood what we
  certify); clean auth story via existing SMART/OAuth machinery; the UI could later
  front non-RPMS backends (Greenway-overlay motion) unchanged.
- *Against:* contradicts ADR 0002's "engine is the complete product" stance; a second
  repo/deployment to operate; SPA-only stacks fight RPC latency and offline realities;
  no second host exists yet to justify the split (same reason ADR 0002 rejected a
  separate UI engine).

**Recommendation: (i) with (ii)'s discipline — the UI ships in the engine (extending,
not superseding, ADR 0002), but is built *API-first against the engine's own FHIR
surface*.** UI code consumes the same serializers/services the FHIR controllers use
(or the HTTP API itself where practical), never gateways directly. SMART-on-FHIR
remains the seam for third-party apps; because our UI exercises the same surface, every
screen we build hardens the API those apps rely on. If a second host or non-RPMS
backend later makes a standalone SPA worthwhile, the API-first discipline makes that
extraction cheap instead of a rewrite.

Auth: the host (Jumpstart Pro) owns login/MFA/session per ADR 0002; the engine UI
authorizes via the host session carrying DUZ + RPC context, and via Doorkeeper/SMART
scopes for anything app-launched. No engine-local sign-on is built (ADR 0002's
migration-debt note stands).

## Phased plan

| Phase | Scope | Gate to next |
|---|---|---|
| **0 — now** | VueCentric is the clinical UI. Land YDB sign-on (rpms-ops#343); prove reg/sched parity (#412/#413/#416). Engine stays headless. | Sign-on works; parity suite green. |
| **1** | Read-only clinical review in the engine: patient search, chart summary (problems, meds, allergies, vitals, labs, immunizations) over the existing FHIR controllers. Host-session auth. | Clinicians can review a chart in the browser; API gaps found are fixed in the FHIR layer, not bypassed. |
| **2** | Write workflows, in order of demand: scheduling/registration (twin work already proves the RPC path), then documentation (notes + e-signature), then orders/med requests. Each write lands as FHIR-surface capability first, UI second. | Priority workflows usable without VueCentric for those roles. |
| **3** | SMART app ecosystem: EHR-launch third-party apps from within the UI (launch context already implemented); decommission VueCentric per-site as workflow coverage allows. | VueCentric optional, not required. |

## Consequences

- Clinics get a full clinical front end (VueCentric) without waiting on UI development;
  engine roadmap stays focused on the FHIR/RPC surface that everything else builds on.
- We take a dependency on the native-client sign-on landing (rpms-ops#343) — already a
  P1 elsewhere; this ADR makes it the formal gate for clinical go-live.
- The (g)(10) surface becomes load-bearing for our own UI, so API completeness bugs
  surface early and fixes accrue to third-party SMART apps too.
- ADR 0002's placement decision is reaffirmed; this ADR adds the *how* (API-first) and
  the *when* (phases), and defers any standalone-SPA split until a concrete second host
  exists.
- Risk: API-first UI development is slower per-screen than direct gateway coupling.
  Accepted — it prevents a forked data path and buys extraction optionality.

## References

- Issue #440 (audit finding; this ADR is its deliverable)
- ADR 0002 — staff UI lives in the engine (placement; extended by this ADR)
- `config/routes.rb`, `app/controllers/lakeraven/ehr/`, `app/gateways/lakeraven/ehr/`,
  `app/views/layouts/lakeraven/ehr/application.html.erb`
- rpms-ops#343 (CIA/VueCentric broker on YottaDB; sign-on gate)
- #412, #413 (BPRM reg/sched digital twin), #416 (HTTP parity tests)
