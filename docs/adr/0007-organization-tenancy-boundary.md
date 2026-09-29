# ADR 0007: "Organization" names three different things, and only one of them is the tenancy boundary

**Status:** Proposed
**Date:** 2026-09-29

## Scope, and what this ADR deliberately is not

This ADR fixes the **meaning of the word** and names the consequence for where
the tenancy boundary is enforced. It does not design the broker connection
layer (rpms-rpc#234), does not interpret HIPAA, and does not decide any
deployment's configuration — divisional setup is a site decision (L3), not an
engineering one.

It exists because lakeraven-ehr#553 could not be built. Not because the defect
was unclear, but because three different concepts share one word, and the fix
differs depending on which was meant.

## The collision

| Term as used | What it actually is | Level |
|---|---|---|
| FHIR `Organization` resource | RPMS **file 4 INSTITUTION**, via `BHDO INST DATA` — `ien`, `name`, `station_number`, address | facility, and a **reference list** |
| `oauth_applications.organization_id` | free-form **string** column, no foreign key, no validation, no stated referent | undefined |
| the boundary that must not leak | the entity whose patients another entity must never read | tenancy |

File 4 is a reference file: it lists institutions generally, including ones a
site merely refers patients *to*. A file-4 IEN is therefore not a tenancy
marker, and `organization_id` pointing at one would not mean what the name
suggests.

RPMS supplies a fourth concept the code does not model at all: `DUZ(2)`, the
signed-on **division**. It is load-bearing in the RPC layer — a patient's
health record number is issued per division (`$$HRN^AUPNPAT(dfn,DUZ(2))`), and
AG registration edits file against `DA=DUZ(2)`. RPMS's own patient identity is
division-scoped whether or not we model it.

## Decision

**1. The tenancy boundary is the RPMS instance.** One tribal health program
runs one RPMS; one deployment reaches one RPMS. Tenancy, deployment and
sovereign data boundary are the same object. This is what `organization_id`
means, and the column should become a validated reference to it rather than
free text.

**2. It is NOT the FHIR `Organization` resource.** That keeps meaning file-4
institution and keeps serving `/fhir/Organization`. The two need different
names in code and prose. This collision is the whole reason #553 stalled, and
renaming is the durable half of this ADR.

**3. Enforcement is connection selection, not read filtering.** Today
`RpcSupport.broker` returns one process-global `RpmsRpc.client`, so every read
in the process reaches one RPMS and there is no second tenant's data to
filter. When rpms-rpc#234 makes connections per-session or pooled, **the
token's tenancy binding selects the connection**. Cross-tenant reads become
impossible rather than filtered.

Consequently **lakeraven-ehr#553 is delivered by rpms-rpc#234**, not before it
and not separately. A filter written today would specify behaviour against a
partition that does not exist, and its tests would assert fiction.

**4. Divisions are out of scope while sites remain single-division.** Per
clinical operations guidance, a separate RPMS division is warranted when a
service line has **its own TIN, separate financials, or its own pharmacy set**
— and is not recommended otherwise. Where those do not hold, one instance
holds one division and per-read division scoping buys nothing.

## The trigger that ends this

Decision 4 rests on a configuration fact, not a law. **Revisit this ADR when
any of the divisional criteria above becomes true for a served site** — most
plausibly a service line acquiring its own TIN for billing, which is a live
possibility wherever FQHC or revenue-cycle work is underway.

At that point one instance holds two divisions, connection selection no longer
separates them, and a per-read division control becomes necessary. That is a
different design from this one; do not retrofit it silently.

## Interim control

Until #234 lands, the binding is recorded at mint and unenforced. #529 added a
mint-time guard: token issuance refuses once a second distinct organization is
registered (compared normalised, so a spelling variant is not a second
tenant). It converts an unenforced assumption into one that fails loudly at
the moment it stops holding. **It is removed by #234, not kept.**

## Consequences

- `#234` must not ship without tenancy-aware connection resolution; the
  dependency between it and `#553` is the reverse of how it was first recorded.
- `organization_id` should be validated against the tenancy referent this ADR
  names, not left free-form.
- Code and docs must stop using "organization" for both concepts. New names are
  a follow-up, and the FHIR resource keeps the existing one.
- Nothing here changes the FHIR API surface.

## Alternatives rejected

**Filter reads by organization now.** Rejected: there is no second tenant to
filter, so the control would be untested in the only way that matters, and it
would sit on the hot path of every clinical read for no present benefit.

**Treat the file-4 institution as the tenant.** Rejected: file 4 is a reference
list including external facilities. It cannot carry tenancy.

**Model divisions immediately.** Rejected as premature while served sites are
single-division, but explicitly deferred rather than dismissed — see the
trigger above.
