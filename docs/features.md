# Feature roadmap

This engine is built feature by feature, with each feature backed
by a Cucumber BDD scenario set as the spec. This file lists the
features in their intended ship order, with a brief note on what
each one covers and what its acceptance looks like.

The pattern for every feature PR:

1. **Land the `.feature` file first** — copied or adapted from a
   prior BDD codebase, kept as the unmodified spec the new code
   has to satisfy
2. **Land the step definitions** — minimal step glue, no business
   logic
3. **Land the implementation** — controllers, models, services,
   adapter calls — making each scenario go green one at a time
4. **Land the migration** if any new persistent state is required
   (subject to ADR 0002 — no PHI columns)

Each feature ships as a single PR. Cross-feature refactors do
not happen until at least three features have landed and a real
duplication shows up.

## v0.1 — Core read API

These are the features that make the engine answer a SMART-on-FHIR
patient query end to end.

### 1. patient_search

**What:** Free-text and structured patient search. Backs the
typeahead in launch flows and the FHIR `Patient?name=...` and
`Patient?identifier=...` queries.

**Why first:** It's the entry point to the FHIR API. Until you can
find a patient, nothing else in the engine is reachable.

**Acceptance:**
- Search by name (partial, case-insensitive)
- Search by FHIR `Identifier` (system + value pair)
- Search by date of birth
- Pagination per FHIR Bundle conventions
- Empty result is a valid Bundle, not an error
- Tenant isolation enforced (results scoped to current tenant)
- All hits returned as opaque patient identifiers; no PHI
  persisted in the engine

### 2. provider_search

**What:** Practitioner search by name, NPI, and credential.

**Why second:** Symmetric with patient_search and shares most of
its scaffolding (Bundle pagination, FHIR identifier handling,
tenant scoping). Land it next while that code is fresh.

**Acceptance:**
- Search by name
- Search by NPI (FHIR `Identifier` with the standard NPI system URI)
- Search by specialty / qualification code
- Pagination and tenant isolation per patient_search
- Practitioner identifiers are opaque tokens

### 3. us_core_patient_api

**What:** FHIR R4 `Patient` read endpoint conforming to the
[US Core Patient profile](http://hl7.org/fhir/us/core/StructureDefinition-us-core-patient.html).

**Why third:** This is the first feature that returns a fully-formed
FHIR resource. Lays down the resource serializer pattern that
every other resource type will reuse.

**Acceptance:**
- `GET /Patient/{identifier}` returns a US Core conformant Patient
- Resource includes the required US Core elements
- Tribal enrollment and other IHS-specific extensions emitted
  when the backend supplies them
- Inferno US Core Patient test suite passes against the engine
- Returns 404 for unknown identifier; 403 for cross-tenant access

## v0.1 — Authentication

The engine ships with both flavors of SMART launch from the start.
Splitting them into separate v0.x releases creates an awkward window
where the engine has standalone auth but no EHR launch (or vice
versa); ship both together.

### 4. fhir_smart_authentication

**What:** SMART on FHIR standalone launch — OAuth 2.0 with the
SMART scopes (`patient/*.read`, `user/*.read`, etc.) and PKCE
required by ONC G10.

**Acceptance:**
- `.well-known/smart-configuration` returns the right metadata
- Authorization endpoint accepts SMART scope strings
- Token endpoint issues access tokens with the requested scopes
- Refresh token flow works
- PKCE enforced for public clients
- Inferno SMART App Launch test suite passes for standalone

### 5. smart_ehr_launch

**What:** SMART EHR launch — the launch context flow where an
EHR initiates the app launch and passes a `launch` parameter
that resolves to a patient and (optionally) an encounter.

**Acceptance:**
- `launch` parameter resolves to a patient_identifier and
  optional encounter_identifier
- Patient context is available in the issued access token
- App can call `Patient/{identifier}` immediately after launch
  without an additional patient picker
- Inferno SMART App Launch test suite passes for EHR launch

## v0.1 — Compliance

### 6. phi_audit_logging

**What:** Audit log for every PHI-touching request — who, what,
when, why. Stored as engine-internal rows referencing tokens
(per ADR 0002).

**Acceptance:**
- Every authenticated FHIR read produces an `AuditEvent`-shaped
  log entry
- Audit entries include actor (user_identifier),
  resource (e.g. patient_identifier), action, timestamp, and
  outcome
- Audit entries are queryable via a `GET /AuditEvent` endpoint
  scoped to the current tenant
- ONC G10 audit conformance criteria satisfied
- No PHI in the audit row itself — only tokens

## After v0.1

These features are out of scope for the initial release but live
on the roadmap so the v0.1 design doesn't paint itself into a
corner:

- **Patient resource WRITE** — write paths to the backend; gated
  on having a clean read API first
- **Additional FHIR resources** — Observation, Condition,
  MedicationRequest, Encounter, AllergyIntolerance
- **Bulk Data API** — `$export` operation
- **Subscriptions / notifications** — FHIR Subscription resource
- **Composite adapter** — combine RPMS reads with non-RPMS sources
  per resource type

## How to add a feature to this list

A feature graduates from "idea" to "on the roadmap" only when:

1. There is a known backend RPC (or other adapter call) that can
   satisfy it — verified in the [`rpms-rpc` ledger](https://github.com/lakeraven/rpms-rpc/blob/main/docs/rpcs.md)
   when it's an RPMS read
2. There is a test surface — usually an Inferno test suite or a
   Cucumber feature file from a prior codebase — that defines
   what "done" looks like
3. The feature does not violate ADR 0001 (scope) or ADR 0002 (PHI)

If a feature requires PHI persistence, it doesn't land here — it
lands in a host application that's already inside the PHI
boundary.
