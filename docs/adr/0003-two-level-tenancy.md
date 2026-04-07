# ADR 0003: Two-level tenancy (tenant + facility, row-based)

**Status:** Accepted
**Date:** 2026-04-07

## Context

This engine is designed to run in deployments that span more than
one organization and more than one site within an organization:

- A single organization may operate dozens of clinic facilities,
  each with its own staff, its own patient catchment, and its own
  reporting boundary. Patient data from one facility must not bleed
  into another even though they're administered together.
- A managed deployment may host multiple organizations on the same
  infrastructure. Their data must be cleanly separated, audited
  separately, and exportable independently.

The candidate isolation strategies are:

1. **Per-tenant database** (one Postgres database per organization)
2. **Per-tenant schema** (Postgres schemas, e.g. via the Apartment gem)
3. **Row-based isolation** (every table carries a tenant key,
   queries scope by it, default scopes enforce it)
4. **Some combination** (e.g. per-tenant database with row-based
   facility isolation inside each)

We also have the deployment reality that the engine runs against an
RPMS / VistA backend which already provides physical isolation for
clinical data — separate broker instances per site, separate MUMPS
globals, separate audit trails. The engine's database is metadata
on top of that, not the canonical record.

## Decision

The engine uses **row-based, two-level tenancy**:

- **Level 1 — Tenant.** An organization. Identified by
  `tenant_identifier` (an opaque token, see ADR 0004). Every
  engine-managed table carries `tenant_identifier` as a non-null
  column with an index.
- **Level 2 — Facility.** A site within a tenant. Identified by
  `facility_identifier`. Every engine-managed table that maps to
  a facility-scoped concept also carries `facility_identifier`
  as a non-null column with an index.

A request's tenant and facility are established at the request
boundary (typically from the SMART launch context or an
authenticated session) and stored in `Lakeraven::EHR::Current`
for the duration of the request. Models enforce isolation via
default scopes that read from `Current` and **fail loud** if it
is not set:

```ruby
default_scope do
  if Current.tenant_identifier.blank?
    raise MissingTenantContextError, "..."
  end
  where(tenant_identifier: Current.tenant_identifier)
end
```

The same pattern applies for `facility_identifier` on
facility-scoped models.

## Why row-based, not Apartment

- **Engine compatibility.** Apartment's monkey-patching of
  ActiveRecord plays badly with mountable engines that ship their
  own models. We discovered this the hard way and don't want
  to relitigate.
- **Scale.** A row-based scheme handles hundreds of facilities per
  organization without requiring schema-level setup or per-tenant
  migrations. Schema-per-tenant becomes operationally painful at
  the upper end of plausible deployment scale.
- **The backend already isolates physically.** RPMS gives us
  per-site isolation at the broker level. The engine database is
  bookkeeping; we don't need a second physical isolation layer to
  protect clinical data.
- **Simpler ops.** One database, one connection pool, one backup
  job, one set of credentials. Tenant onboarding is a row insert,
  not a `CREATE SCHEMA` or a database provisioning ticket.

## Why fail-loud, not silent-fallback

A `default_scope` that silently returns `where("1=0")` when no
tenant context is set is the worst of both worlds: queries return
empty results in production, tests pass because they don't notice
the missing context, and the bug surfaces as "patient X disappeared"
in a real deployment.

Raising `MissingTenantContextError` instead means:

- Tests catch the missing context immediately
- Background jobs that forgot to set `Current` blow up loudly the
  first time they run, not the first time a customer notices
- Console sessions that try to query without `with_tenant(...)`
  fail rather than returning misleading-empty results

The cost is that every test has to wrap model access in
`with_tenant("tnt_test") { ... }`. That's a feature, not a bug —
it forces tests to be explicit about the tenant they're exercising.

## Identifier shape

`tenant_identifier` and `facility_identifier` are **opaque tokens**
(prefixed ULIDs per ADR 0004), not numeric IDs and not human-readable
slugs. Specifically:

- `tnt_01H...` for tenants
- `fac_01H...` for facilities

Opaque so they can't be guessed, prefixed so they can't be
confused for any other identifier in a log line, and lexicographically
sortable so range queries work without an extra timestamp column.

## Polymorphic associations

Models that join across tenancy boundaries via polymorphic
associations (e.g. an audit log entry that references either a
patient token or a practitioner token) must validate that the
associated record's `tenant_identifier` matches the parent's. This
check is enforced at the model level, not just at the database
level — the database does the storage, the model does the policy.

## Consequences

### Positive

- Strong isolation guarantee enforced in the application layer
  even if a query forgets to scope explicitly
- Fast onboarding (row insert) and fast offboarding (delete by
  `tenant_identifier`)
- Simple operational story: one database, standard backups
- Tests that pass without a tenant context are impossible by
  construction

### Negative

- Every model that joins to a tenancy-bearing model must propagate
  `tenant_identifier`. Forgetting it is caught at test time by
  the fail-loud default scope, but there's a small recurring tax
  on every new model.
- Cross-tenant analytics is intentionally hard. That's the point,
  but it does mean reporting infrastructure has to live in a
  separate system that's authorized to skip the scope.
- The `Current` request-store pattern requires discipline in
  background jobs and worker code — every job has to set the
  context before touching any model.

### Alternatives considered

- **Apartment gem (schema-per-tenant).** Rejected for engine
  compatibility and operational complexity at scale.
- **Database-per-tenant.** Rejected for the same reasons plus
  the cost of running hundreds of Postgres instances.
- **Single-level tenancy (no facility).** Rejected because real
  deployments need facility-level reporting and access scoping
  that mirrors how the backend organizes data.
- **Silent default scope.** Rejected per the fail-loud rationale
  above.

## References

- ADR 0001 — Engine scope
- ADR 0002 — PHI tokenization (the data this tenancy model
  protects access to)
- ADR 0004 — Identifier convention (the prefixed-ULID scheme used
  for `tenant_identifier` and `facility_identifier`)
