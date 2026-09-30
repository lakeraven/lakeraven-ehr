# ADR 0007: "Organization" names three different things, and only one of them is the tenancy boundary

**Status:** Proposed
**Date:** 2026-09-29 · **Revised after round-1 gate:** 2026-09-29

> **Revised.** A two-vendor gate refuted two claims in the first draft and
> corrected a third. The tenancy model below is the maintainer's decision on a
> point the two seats split on. See `gate/runs/lakeraven-ehr-556/r1/`.

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
health *record number* is issued per division (`$$HRN^AUPNPAT(dfn,DUZ(2))`)
and AG registration edits file against `DA=DUZ(2)`.

**The DFN is not division-scoped.** An earlier draft said RPMS patient
identity is division-scoped; that overstates it. Only the HRN subrecord is
facility-scoped — the DFN is instance-global
(`rpms-rpc/lib/rpms_rpc/api/registration.rb:80-93`). A read by DFN therefore
crosses divisions regardless of `DUZ(2)`, which makes division membership a
weaker boundary than it appears, not a stronger one.

## Decision

**1. The tenancy boundary is the COVERED ENTITY, modelled explicitly.** Not
the RPMS instance, and not inferred from deployment topology. A tenant is a
first-class record naming the entity whose PHI must not leak; instances and
divisions are attributes of it, not definitions of it.

Three identities must stay distinct, because #234 lets one deployment reach
several instances and a deployment identifier therefore cannot name a tenant:

| | What it identifies | Stable across |
|---|---|---|
| **deployment** | one running process/host of this app | nothing — it is an operational fact |
| **instance** | one RPMS/YottaDB system the app connects to | redeploys, scaling, host moves |
| **tenant** | the covered entity accountable for the PHI | instance moves and migrations |

An instance needs its own stable identifier, assigned by configuration and
recorded on the tenant's approved-instance list — not derived from a hostname,
connection string or deployment name, all of which change without the instance
changing. The application binding refers to a **tenant**, and the tenant
resolves to an approved `(instance, division)` set; nothing resolves through
the deployment.

Explicitly, because HIPAA's covered entity is a *legal* construct and the
governing authority over tribal data may not coincide with it. An organization
serving members of several nations is one covered entity while each nation
retains a claim over its own people's records under OCAP. The model must be
able to express a domain NARROWER than the covered entity without redefining
the term; the covered entity is the default, not the ceiling.

`organization_id` becomes an immutable foreign key to that record rather than
free text.

**2. It is NOT the FHIR `Organization` resource.** That keeps meaning file-4
institution and keeps serving `/fhir/Organization`. The two need different
names in code and prose. This collision is the whole reason #553 stalled, and
renaming is the durable half of this ADR.

**3. Enforcement is connection selection FIRST, and read scoping where the
two diverge.** The first draft said connection selection was sufficient. Under
decision 1 it is not, and this is the direct cost of choosing the covered
entity over the instance: the two can diverge in both directions. One entity
may run several instances; one instance may serve several entities. Connection
selection cannot separate tenants that share an instance.

So:

- **Necessary:** the token's tenant selects the connection (rpms-rpc#234).
  Where a tenant maps to its own instance, this is the whole control and no
  per-read comparison runs on the hot path.
- **Also required:** `tenant_id` stamped on locally held clinical rows, cache
  keys, background jobs and audit rows, so a shared instance or a shared
  process cannot leak across tenants through state that is not the broker
  connection.
- **NOT on the token.** An earlier revision of this ADR also required stamping
  `tenant_id` on tokens. Dropped: because `organization_id` is an *immutable*
  foreign key (decision 1), an application's tenant cannot change, so the
  token's tenant is already reachable as `token.application.organization_id`.
  Copying it onto `oauth_access_tokens` would mean altering Doorkeeper's schema
  to denormalise a value that cannot drift — and introducing the one way it
  could: two sources of truth that disagree. The immutability of the FK is what
  makes the stamp unnecessary; if that immutability is ever relaxed, this
  decision must be revisited in the same change.
  (Raised by the step-0 gate seat on lakeraven-ehr#553, Gemini 3.1 Pro.)

`RpcSupport.broker` is one process-global `RpmsRpc.client` today, so nothing
in-process is tenant-aware at all. That is the gap #234 opens and this decision
closes.

**And most clinical reads do not even reach `RpcSupport.broker`.** The gateways
call the `RpmsRpc::*` module API directly — `ConditionGateway` calls
`RpmsRpc::Problem.for_patient`, `VitalGateway` calls `RpmsRpc::Vital.template`
— and those modules resolve `RpmsRpc.client` themselves (e.g.
`rpms-rpc/lib/rpms_rpc/api/problem.rb:60`). `RpmsRpc.client` appears in exactly
one place in this repo, `app/gateways/lakeraven/ehr/rpc_support.rb:34`, which is
why the bypass is easy to miss: the gateways never name it. So the
`AuditedBroker` wrapper — and any tenant binding attached to it — is skipped on
those paths today.

The consequence for #553 is concrete: **pooling connections in #234 does not by
itself bind those reads to a tenant.** A per-session or pooled client that is
selected inside `RpcSupport.broker` is simply not consulted by the gateways.
Either the `RpmsRpc::*` modules must take an explicit client (or read one from
a request-scoped context), or every gateway must route through the wrapper.
Choosing between those two, and doing it, is #553's work and belongs in its
scope — not an implicit follow-on of #234.

Note also where the binding lives today: `organization_id` is a column on the
OAuth **application**, not a claim on the token. FHIR authentication does not
retrieve it, so even a tenant-aware client has nothing to select on until #553
carries the authenticated application's binding into the request.

**lakeraven-ehr#553 is therefore NOT simply delivered by #234.** #234 delivers
the necessary half. The stamping half is #553's own work and can begin against
the tenant model without waiting.

**4. Divisions are deferred, but detected mechanically rather than trusted.**
A separate RPMS division is warranted when a service line has its own TIN,
separate financials, or its own pharmacy set, and is not recommended
otherwise. Where those do not hold, one instance holds one division.

The first draft deferred on that basis alone. The gate refuted it: the
connection never sets `DUZ(2)`, so RPMS falls back to the signed-on user's
default division. A site that adds a division does not get an error — it gets
silently wrong reads. Deferral is only safe with a detector, tracked as
rpms-rpc#293.

## The detector that ends this

The first draft asked a human to revisit this ADR when a service line acquired
its own TIN — that is, to recognise a billing decision as an architecture
decision, months later. Both gate seats rejected that as insufficient, and
they are right: it fails silently by construction.

Detect the **technical condition**, not the business event:

- Enumerate the instance's divisions authoritatively at startup. `Site.list`
  is not sufficient for this.
- **Fail closed** when an instance exposes a division that is not mapped to a
  tenant, rather than proceeding on a default.
- Capture the signed-on `DUZ(2)` and refuse when it is not allowlisted for the
  token's tenant.
- Require explicit `(tenant, instance, division)` configuration before a
  connection is enabled.

Tracked as rpms-rpc#293.

**Open: `DUZ(2)` for system/ tokens.** The detector above captures the signed-on
`DUZ(2)` and refuses when it is not allowlisted for the token's tenant. That
presumes a signed-on user, and a backend-services (`system/`) token has none.
Where one instance serves several tenants by division, nothing here says how the
broker initialises a connection's `DUZ(2)` from tenant configuration alone. That
mechanism is unspecified and must be settled before a multi-division instance is
served by a system/ token — rpms-rpc#293's scope, not #553's.
(Raised by the step-0 gate seat on lakeraven-ehr#553, Gemini 3.1 Pro.)

## Interim control

An issuance-time guard (#529) refuses to mint a backend-services token once a
second distinct organization is registered, compared normalised so a spelling
variant is not a second tenant.

**Its reach is narrower than the first draft claimed.** It observes
backend-client registrations only. It does not see a tenant that arrives as a
division, one that holds no backend client, or credentials already issued. It
is a tripwire on one path, not a boundary, and it is removed by #234 rather
than kept.

## Consequences

- A **tenant record** must exist before either half of the enforcement can be
  built. `organization_id` becomes an immutable foreign key to it, associated
  with approved instances and division IENs.
- `#234` must not ship without tenant-aware connection resolution — and
  tenant-aware connection resolution is not sufficient on its own, because the
  clinical gateways bypass `RpcSupport.broker` and resolve `RpmsRpc.client`
  through the `RpmsRpc::*` modules. #553 must close that bypass explicitly.
- An **instance identifier** must be configuration-assigned and stable, and must
  not be derived from deployment facts (hostname, connection string, deployment
  name). Tenants hold approved `(instance, division)` pairs; deployments hold
  none.
- `#553` is no longer purely downstream of `#234`: the stamping half is its
  own work. The board dependency recorded as `#234 blocked_by #553` should
  stand, since #234 must not land without the tenant model.
- `rpms-rpc#293` — set `DUZ(2)` explicitly and fail closed on an unmapped
  division — is a prerequisite for serving any multi-division instance.
- Code and docs must stop using "organization" for both concepts. The FHIR
  resource keeps the name; the tenancy term needs a new one.
- Nothing here changes the FHIR API surface.

## Alternatives rejected

**Tenancy = the RPMS instance.** Simpler, matches every deployment today, and
makes connection selection the whole control. Rejected because it defines the
boundary by deployment topology rather than by who is accountable for the
data: it cannot represent one entity across two instances, two entities on one
instance, or a governance domain narrower than the covered entity. One gate
seat argued for it on simplicity; the boundary is worth the extra indirection.

**Filter reads by organization now, before the tenant model exists.**
Rejected: there is no second tenant to filter, so the control would be
exercised only by fabricated fixtures.

**Treat the file-4 institution as the tenant.** Rejected: file 4 is a
reference list including external facilities. It cannot carry tenancy.

**Defer divisions on operational guidance alone.** Rejected after review — see
the detector above. Deferring is fine; deferring without detection is not.
