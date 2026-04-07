# ADR 0002: PHI tokenization (zero PHI at rest)

**Status:** Accepted
**Date:** 2026-04-07

## Context

A FHIR-fronted EHR engine inevitably handles Protected Health
Information — names, dates of birth, addresses, encounter notes,
clinical observations. The default Rails approach is to model these
as columns on `patients`, `practitioners`, and so on, and let
ActiveRecord persist them.

That default is the wrong shape for this engine for three reasons:

1. **HIPAA blast radius.** Every machine that runs the engine,
   every backup, every replica, every developer who restores a
   snapshot for debugging, every CI artifact — all of those become
   PHI surface area the moment a patient name is in a column.
   Reducing the number of places PHI can leak from is the single
   highest-leverage HIPAA control.

2. **Source of truth lives elsewhere.** RPMS / VistA already holds
   the canonical patient record in MUMPS globals. Persisting a
   second copy in PostgreSQL means we now have two systems that
   can disagree, and we own the reconciliation problem forever.

3. **Multi-tenancy + tenant-specific encryption are easier when
   you have nothing to encrypt.** A row that holds an opaque
   token doesn't need per-tenant key wrapping. A row that holds
   `first_name = "Jane"` does.

The pattern that works for systems with the same constraint
(payment card data, regulated identifiers) is **tokenization**:
the application stores opaque tokens, and a separate vault
resolves the token to the real value at request time only.

## Decision

`lakeraven-ehr` stores **zero PHI at rest**. The engine's database
holds:

- **Opaque tokens** for clinical entities (patients, practitioners,
  encounters, observations). These are prefixed ULIDs — see
  ADR 0004 (identifier convention).
- **Tenancy keys** (`tenant_identifier`, `facility_identifier`)
  used for row-level isolation — see ADR 0003 (tenancy model).
- **Audit log entries** that record access by token, not by
  patient name or DOB.
- **Engine-internal bookkeeping** (sessions, OAuth grants, SMART
  launch contexts) that may reference tokens but never names.

When the engine needs to answer a FHIR request, it:

1. Resolves the token to the backend identifier (DFN, IEN, etc.)
2. Calls the adapter to fetch live data from the backend
3. Renders the response as a FHIR resource
4. Returns it without persisting any of the resolved values

The adapter is the **vault interface**. The reference adapter
(supplied by `rpms-rpc`) calls the live RPMS broker; alternative
adapters can point at a FHIR server, a fixture, or any other source
of truth, but they all share the contract: *the engine asks for
data by token; the adapter resolves it; the engine never writes the
result back to its own tables.*

## What counts as PHI for this rule

The 18 HIPAA Safe Harbor identifiers (names, dates more granular
than year, addresses smaller than state, phone, fax, email, SSN,
MRN, account numbers, certificate/license numbers, vehicle IDs,
device IDs, URLs, IPs, biometric IDs, full-face photos, any other
unique identifying number/code), **plus** the clinical content
those identifiers attach to (diagnoses, medications, lab results,
notes, encounter records).

The rule is conservative on purpose: if a column could plausibly
correlate to a real patient, it doesn't go in the database.

## Exceptions (and how to handle them)

There are a few legitimate cases where the engine needs to remember
something across requests:

- **Cached search index for typeahead.** Names on a search index
  feel like PHI, because they are. Don't build the typeahead in
  this engine — proxy it through to the backend on every keystroke,
  or build it in a host application that's already inside the PHI
  boundary.
- **Audit log entries.** These store *who accessed which token
  when*, not the underlying values. A token hashed via the
  `RpmsRpc::PhiSanitizer` HMAC scheme is fine for log lines.
- **OAuth and SMART session state.** Patient context in a launch
  is stored as a token reference, not as a name.

If a feature absolutely requires PHI persistence in the engine
(not the host application) — stop, write a new ADR proposing the
exception, link it back here, and get explicit signoff before
merging.

## Consequences

### Positive

- The engine's database can be backed up, replicated, sampled
  for development, and shared with auditors without leaking PHI.
- A breach of the engine's PostgreSQL instance leaks tokens, not
  patient records. The tokens are useless without access to the
  vault (the live RPMS broker, gated by its own auth).
- Encryption-at-rest on the database becomes a defense-in-depth
  measure rather than the only thing standing between a stolen
  disk image and a HIPAA notification.
- The engine can ship as open source. If the engine stored PHI,
  every contributor's local checkout would be a compliance hazard.

### Negative

- Every read costs an adapter round trip. Caching has to live
  outside this engine (in front of it, with its own PHI controls)
  rather than inside it.
- Reports that aggregate across patients (e.g. utilization
  reports) cannot be built by joining engine tables. They have to
  call the backend or live in a separate analytics system that
  has its own PHI handling.
- Some FHIR conformance tests expect the server to remember a
  resource between calls. Where the spec allows it, the engine
  will rely on the backend's idempotency; where it doesn't, the
  test setup needs to seed the backend, not the engine database.

### Alternatives considered

- **Store PHI with column-level encryption.** Reduces leak surface
  but doesn't eliminate it: backups, logs, error tracebacks, and
  test fixtures all still touch decrypted values. Also creates
  the key-management problem we'd rather not own.
- **Store PHI with tenant-scoped encryption keys.** Same problems
  plus a much harder operational story (key rotation, lost-key
  recovery, disaster recovery). Worth considering only if a
  concrete feature requires PHI persistence; revisit then.
- **Cache resolved values for the duration of a request.** Fine
  inside a single Ruby process — caching in instance variables
  during one controller action is not "at rest." Don't extend
  the cache lifetime beyond the request.

## References

- `RpmsRpc::PhiSanitizer` — the HMAC-SHA256 hashing scheme used to
  put token-shaped values into log lines safely
- ADR 0001 — Engine scope (specifically the "no PHI persistence"
  out-of-scope bullet this ADR formalizes)
- ADR 0003 — Two-level tenancy (the row-isolation layer that
  protects tokens from cross-tenant access)
- ADR 0004 — Identifier convention (the prefixed-ULID scheme used
  for tokens)
