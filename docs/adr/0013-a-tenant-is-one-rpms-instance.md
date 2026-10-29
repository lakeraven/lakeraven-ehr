# ADR 0013: A tenant is exactly one RPMS instance, and an instance is never shared between tenants

**Status:** Proposed. The maintainer's position below was given on 2026-10-29. This text has not been through the gate, and the compliance premise has not been reviewed by counsel.
**Date:** 2026-10-29
**Amends:** ADR 0007 (decision 1's "one instance may serve several entities", and its rejection of "tenancy = the RPMS instance") and ADR 0008 (its "does not settle shared-instance tenants" and the trigger for sequence step 4).
**Builds on:** ADR 0011 section 6 (a system token runs as a named service account), ADR 0012 (the request context carries the tenant), lakeraven-ehr#553.

## Context

ADR 0007 made the tenant the covered entity and let the covered entity and the RPMS instance diverge in both directions: one entity on several instances, and several entities on one instance. Because of the second case it required read scoping and `tenant_id` stamping as well as connection selection, and it rejected "tenancy = the instance" for being unable to represent two entities on one instance.

The maintainer's position is that an organization is one RPMS instance, and that two covered entities sharing an instance is not a topology to support. A read under one entity's authority would reach another entity's patients, and the maintainer treats that as a breach. This ADR does not interpret HIPAA or classify any occurrence; that is for counsel. It takes the position as its premise.

The consequence for design is that a shared instance is an error state to refuse, not a case to engineer around.

## What a system token does today

Measured on `main` at 966bd486:

- **Authorization identity.** `current_duz` returns nil for a header or system token, deliberately: "system callers must not inherit a human's signature" (`smart_authentication.rb`).
- **Connection.** Gateways reach RPMS through `RpcSupport.broker`, which wraps `BackendRegistry.current.client`, which is `RpmsRpc.client`, one process-global. The direct `RpmsRpc::*` calls (ADR 0008 counts 87) resolve the same client. Nothing selects a connection by token or by application.
- **So** the RPMS-side identity of a system read is whatever the global client is signed on as. ADR 0011 describes the CIA case as the last clinician to sign in. That case was not re-measured here.
- **The binding.** `oauth_applications.organization_id` is checked for blankness when a token is minted and referenced nowhere else.
- **The interim guard** refuses to mint once a second distinct organization is registered. It compares normalised strings, not endpoints, so two labels that point at the same broker would not trip it.

## Decision

1. **Tenant and instance are one to one.** Each tenant is approved for exactly one instance, and each instance is approved for exactly one tenant. An entity that runs two instances is two tenants.
2. **The mapping is validated on the physical endpoint, not on the label.** Configuration load fails when:
   - two tenants name the same instance;
   - two instance identifiers resolve to the same broker endpoint (host, port and, where it applies, namespace);
   - a tenant names no instance, or more than one;
   - an enabled connection belongs to no tenant.

   A bad topology stops the app from booting. It does not wait for a mint-time refusal.
3. **Instance identity stays configuration-assigned and stable** (ADR 0007). Where the instance can attest which site it is, the connection compares that against configuration on connect and refuses on a mismatch. Whether a stock RPC provides this is not verified (see below).
4. **A system token runs on its tenant's connection as a named service account.** The client's registration gives the tenant (ADR 0008 binds it to a client), the tenant gives the connection, and the session is the client's service account on that instance (ADR 0011 section 6). The account is provisioned on that instance only, with credentials from host secrets. With no account configured the request gets 503. It never runs on a clinician's session and never reaches another tenant's instance. The account's RPMS keys are the ceiling on what the token can do inside the tenant; scopes only narrow them.
5. **Divisions never separate tenants.** A second division on an instance belongs to the same tenant. The division detector (rpms-rpc#293) stays, but its job is to catch a mis-mapped division, not to partition tenants.
6. **Audit.** Every system read records the tenant, the instance, the service-account DUZ, the client application and the request id. A refused attempt to reach another tenant is recorded as a security event, not just a denied request.
7. **What stays from ADR 0007 and ADR 0008.** The tenant record with `organization_id` as an immutable foreign key, the scoped client of ADR 0008 option B, and `tenant_id` stamping on locally held rows, cache keys, jobs and audit rows. The stamping is still required, because one process or one local database can serve several tenants even when no RPMS instance is shared. ADR 0008 step 4 is now needed before a second tenant shares a **process or database**, not before one shares an instance.
8. **The interim guard is replaced by decision 2.** It is removed when the scoped client is live, as ADR 0007 already says.

## Acceptance test

Two tenants, each with its own mock instance holding distinct patients:

- A token for tenant A that asks for tenant B's patient is refused.
- Registering both tenants on one endpoint fails configuration load.
- A tenant with no service account is refused with 503 and never falls back to a user session.
- Break each check on purpose and confirm the test goes red. An unverified gate is a comfort, not a control.

## Consequences

- A tenant record must exist before any of this is built (ADR 0007), and the configuration needs a place for the tenant-to-instance mapping. Where it lives is for the implementation to settle; it is operator-held deployment configuration, never a client-registration field.
- ADR 0007's "several entities on one instance" branch and its detection logic become dead design. Its table of divergences loses one row.
- A sandbox or test instance of an entity is a separate tenant. Any state shared between them is cross-tenant state and is treated as such.
- Onboarding a tenant now includes provisioning its service account, which is a site task (L3), not an engineering one.

## Alternatives rejected

**Support shared instances with row scoping** (the path ADR 0007 left open). The boundary would be derived from RPMS data that carries no tenant, so a single missed filter is a disclosure. The maintainer's position makes the case unsupported rather than merely hard.

**Tenancy is the instance, with no tenant record.** A deployment label is not stable across moves and migrations, which is the reason ADR 0007 kept the tenant first-class. That reasoning still holds. The tenant record stays; it is only constrained to one instance.

**Let a system token ride the shared client.** The state of the code today. It leaves the identity of a system read to whoever signed in last, and ADR 0011 section 6 already rejects it.

## Not verified

- **Instance attestation.** Whether a stock RPC reports which site an instance is. If none does, decision 3's runtime comparison is not available and decision 2 carries the whole load. We do not write our own M.
- **ADR 0011's last-clinician claim** for system calls under CIA. Read from the ADR, not re-measured.
- **Counsel.** The compliance premise, the breach classification, and how it interacts with 42 CFR Part 2 (ADR 0006).
- **Real deployments.** Whether any deployment today has one entity on two instances, and what "two tenants" means for it.
