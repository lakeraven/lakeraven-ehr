# ADR 0004: Identifier convention (`id` vs `identifier`)

**Status:** Accepted
**Date:** 2026-04-07

## Context

A FHIR engine that talks to multiple backends and stores opaque
tokens for clinical entities (per ADR 0002) ends up with several
distinct things that all want to be called "id":

- Rails-internal primary keys (`id` columns, integer or UUID)
- VistA / RPMS internal numbers (`DFN` for patients, `IEN` for
  most other File Manager entities)
- FHIR `Resource.id` values returned to clients
- The opaque tokens this engine uses to refer to clinical entities
  without persisting PHI
- Tenancy keys (`tenant_identifier`, `facility_identifier`)
- External identifiers stored on FHIR resources (medical record
  numbers, government IDs)

If all of these get squeezed into a column called `id` or a getter
called `#id`, code becomes ambiguous fast. Worse, because Ruby
doesn't enforce types, the wrong kind of "id" can flow through
several layers of code before anyone notices it's a string ULID
where a DFN was expected, or a DFN where a Rails primary key was
expected.

We need a naming convention that makes the *kind* of identifier
visible at every callsite.

## Decision

This engine uses two distinct words for two distinct concepts:

### `id` / `*_id` — Rails primary keys

Reserved for ActiveRecord primary keys and the foreign keys that
reference them. Always integer or UUID, always managed by Rails,
never leaves the engine's database.

```ruby
class AuditLogEntry < ApplicationRecord
  belongs_to :session  # → session_id (Rails FK)
end
```

If a column is named `id` or ends in `_id`, it is a Rails-managed
primary or foreign key. Nothing else.

### `identifier` / `*_identifier` — Opaque external tokens

Used for everything that crosses the engine boundary or refers to
something the engine doesn't own:

- `patient_identifier` — opaque token for a patient (resolves to
  a DFN via the adapter)
- `practitioner_identifier` — opaque token for a practitioner
- `tenant_identifier` — opaque token for a tenant
- `facility_identifier` — opaque token for a facility
- `encounter_identifier`, `observation_identifier`, etc. — same
  pattern for any clinical entity

The token format is a **prefixed ULID**:

```
pt_01H8XQRZ3VWPGFXQB7K0K9T4MN
^^  ^^^^^^^^^^^^^^^^^^^^^^^^^^
prefix  ULID (Crockford base32, 26 chars, lex-sortable)
```

Prefixes (chosen so each is short, unambiguous, and unlikely to
collide with FHIR resource type abbreviations):

| Prefix | Entity         |
|--------|----------------|
| `tnt_` | Tenant         |
| `fac_` | Facility       |
| `pt_`  | Patient        |
| `pr_`  | Practitioner   |
| `enc_` | Encounter      |
| `obs_` | Observation    |
| `cnd_` | Condition      |
| `med_` | Medication     |
| `mrq_` | MedicationRequest |
| `aud_` | AuditEvent     |

### `*_identifier_value` and `*_identifier_system`

When the engine has to round-trip a FHIR `Identifier` data type
(which carries both a `system` URI and a `value`), it stores them
as paired columns:

```
medical_record_identifier_value      text
medical_record_identifier_system     text
```

This makes it grep-able: any column that contains an externally
meaningful identifier ends in `_identifier`, `_identifier_value`,
or `_identifier_system`. Any column that contains a Rails key
ends in `_id`.

## Why this matters

### At the database layer

Migrations and schema diffs can be audited with a single rule:
*if it ends in `_id`, it should be a Rails-managed key with a
foreign-key constraint. If it ends in `_identifier`, it should be
text and indexed but not constrained to another table in this
database.* The shape of a column tells you which world it lives in.

### At the API layer

FHIR responses serialize the *identifier*, never the `id`. A
controller that returns `@patient.id` has a bug — it's leaking
the engine's internal Rails key as if it were a stable external
reference. A controller that returns `@patient.patient_identifier`
is correct.

### At the log line

`PhiSanitizer.hash_identifier(value)` accepts the opaque token
and produces a 12-char hash for log lines. The function name
contains the word "identifier" because that's what it consumes;
calling it with a Rails primary key would be a code smell that
the reviewer can spot immediately.

## Mapping to RPMS / VistA

`rpms-rpc` returns backend-native identifiers — DFN for patients,
IEN for everything else, sometimes a free-form string. The engine
never stores these directly. Instead, the adapter layer maintains
a mapping table:

```
identifier_resolutions
  identifier            text     -- pt_01H...
  backend               text     -- "rpms"
  backend_native_id     text     -- "12345" (DFN)
  tenant_identifier     text
  created_at            timestamp
```

Resolving a token to a DFN is a single indexed lookup; minting a
new token for a previously-unseen DFN is an insert. The engine
code that needs the DFN asks the adapter, never the database
directly.

## Consequences

### Positive

- The kind of identifier is obvious at every callsite without
  reading documentation
- Database column names self-document which world they belong to
- FHIR responses don't accidentally leak Rails primary keys
- Log lines and audit trails use consistent token shapes
- Renaming a backend identifier (DFN → some FHIR `Identifier`)
  is a single-table change at the resolution layer

### Negative

- Verbose. `patient_identifier` is two characters longer than
  `patient_id` and contributors will be tempted to abbreviate.
  Resist. Reviewers should reject `patient_id` in any column or
  parameter that doesn't refer to a Rails patients table primary
  key (which this engine doesn't have anyway because of ADR 0002).
- An extra resolution hop per request. The cost is one indexed
  lookup; in practice it's negligible compared to the adapter
  call to the backend.

### Alternatives considered

- **Single `id` everywhere.** Rejected. The whole problem this
  ADR exists to solve is the ambiguity that creates.
- **Use `external_id` instead of `identifier`.** Closer to the
  Rails idiom but loses the connection to FHIR's `Identifier`
  data type, which the engine has to deal with anyway. Picking
  the same word the spec uses keeps the mapping obvious.
- **Use opaque integers instead of ULIDs.** Loses lex-sortability
  and the visual prefix that catches misuses in log lines.
  Sequential integers also leak deployment volume to anyone who
  sees one.

## References

- ADR 0002 — PHI tokenization (the reason we need opaque tokens
  in the first place)
- ADR 0003 — Two-level tenancy (uses `tenant_identifier` and
  `facility_identifier` per this convention)
- FHIR R4 `Identifier` data type — https://hl7.org/fhir/R4/datatypes.html#Identifier
- ULID spec — https://github.com/ulid/spec
