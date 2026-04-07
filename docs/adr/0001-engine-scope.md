# ADR 0001: Engine scope

**Status:** Accepted
**Date:** 2026-04-07

## Context

`lakeraven-ehr` is a Rails engine in a multi-engine ecosystem of
public components:

- **[`rpms-rpc`](https://github.com/lakeraven/rpms-rpc)** — pure
  Ruby wire layer for VistA/RPMS RPC brokers
- **`lakeraven-ehr`** — this engine; FHIR/SMART data and identity
- **[`corvid`](https://github.com/lakeraven/corvid)** — case
  management engine, EHR-agnostic via adapter

When a new engine is born, the temptation is to either (a) make it
do too much, absorbing concerns that belong elsewhere, or (b) make
it depend on every adjacent engine to share code. Both lead to a
codebase that can't be reused, can't be tested in isolation, and
can't survive an architectural change to one of its neighbors.

## Decision

`lakeraven-ehr` is scoped to **the EHR data and identity layer**
for an RPMS-backed system. Concretely:

### In scope

- **FHIR R4 reads** for `Patient` and `Practitioner` resources,
  conforming to the US Core profile where applicable
- **Patient and provider search** APIs that back the FHIR reads
- **SMART on FHIR authentication** (standalone launch and EHR launch)
- **PHI audit logging** suitable for ONC G10 / Inferno conformance
- **Multi-tenancy** at the engine level (tenant + facility scoping)
- **Adapter-driven clinical reads** — the engine defines the call
  shape; a host application wires the adapter to `rpms-rpc` (or any
  future backend)

### Out of scope

- **Case management.** Case workflows live in `corvid`. This engine
  knows nothing about referrals, determinations, care teams, or
  any case-domain concept.
- **Billing, claims, eligibility checks via third-party clearinghouses.**
  These integrations live outside this engine.
- **Domain-specific RPC wrappers.** When this engine needs to call
  an RPC, it does so through `rpms-rpc` directly. It does not
  invent its own `Rpms::*` wrapper classes.
- **PHI persistence.** See ADR 0002 (PHI tokenization) — the engine
  stores zero PHI at rest.
- **UI / UX for case workers, providers, or patients.** This engine
  exposes APIs only. The host application brings its own front-end.

## Dependency direction

```
lakeraven-ehr  ←—— sibling ——→  corvid
    ↓ uses
rpms-rpc
```

- `lakeraven-ehr` depends on `rpms-rpc` (the wire layer it actually
  uses for VistA/RPMS reads).
- `lakeraven-ehr` does **not** depend on `corvid`. Corvid is a
  sibling, not a parent or child. Coupling them at the engine level
  would defeat the entire point of corvid's adapter pattern (which
  exists so corvid can run against any EHR backend).
- `corvid` does **not** depend on `lakeraven-ehr`. Corvid is
  EHR-agnostic. A host application wires `Lakeraven::Case.adapter`
  to call into `lakeraven-ehr` services at the application
  boundary — that's where the two meet.

## Consequences

### Positive

- Each engine is testable in isolation. `lakeraven-ehr` does not
  need corvid or any case-domain test data to run its own suite.
- The boundary between data (this engine) and workflow (corvid) is
  enforceable in code, not just documentation.
- A deployment that wants only the FHIR/SMART layer can mount this
  engine and skip corvid entirely.
- A deployment that wants only case management can mount corvid
  against a non-RPMS backend (e.g. a generic FHIR adapter) without
  ever installing this engine.

### Negative

- Some convenience helpers that touch both data and workflow have
  to live in the host application rather than in either engine.
- Cross-cutting concerns (audit logging, tenancy enforcement) that
  apply to both engines need to be implemented twice or extracted
  into a third shared gem if duplication becomes painful. Don't
  extract early — wait for two real consumers.

### Alternatives considered

- **Single mega-engine.** Rejected. The case-domain extraction that
  produced corvid was driven by exactly this reason; rebuilding the
  same coupling here would undo that work.
- **Hierarchical engines (lakeraven-ehr depends on corvid, or
  vice versa).** Rejected for the reasons listed under "Dependency
  direction" above.

## References

- `corvid` adapter pattern (the design that established the
  sibling-engine convention this ADR formalizes)
- `rpms-rpc` ADR 0001 — Scope and no Rails coupling (the analogous
  scope ADR for the wire layer below this engine)
