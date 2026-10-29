# ADR 0013: A tenant is exactly one RPMS instance, and an instance is never shared between tenants

**Status:** Proposed. The maintainer's position below was given on 2026-10-29. Revised after two adversarial reviews (Fable, Composer; both on PR #734). Not yet re-gated. The compliance premise has not been reviewed by counsel.
**Date:** 2026-10-29
**Amends:** ADR 0007 (decision 1's "one instance may serve several entities", its rejection of "tenancy = the RPMS instance", and the partitioning role of its division machinery) and ADR 0008 (its "does not settle shared-instance tenants" and the trigger for sequence step 4).
**Builds on:** ADR 0011 section 6 (a system token runs as a named service account), ADR 0012 (the request context carries the tenant), lakeraven-ehr#553.

## Context

ADR 0007 made the tenant the covered entity and let the covered entity and the RPMS instance diverge in both directions: one entity on several instances, and several entities on one instance. Because of the second case it required read scoping and `tenant_id` stamping as well as connection selection, and it rejected "tenancy = the instance" for being unable to represent two entities on one instance.

The maintainer's position is that an organization is one RPMS instance, and that two covered entities sharing an instance is not a topology to support. A read under one entity's authority would reach another entity's patients, and the maintainer treats that as a breach. This ADR does not interpret HIPAA or classify any occurrence; that is for counsel. It takes the position as its premise.

The consequence for design is that a shared instance is an error state to refuse, not a case to engineer around. **Refusing it at configuration load is necessary and not sufficient.** A boot check on a topology does nothing about the runtime identity of a request, so this ADR also states the runtime property the check protects (decision 6).

## What a system token does today

Measured on `main` at 570c8cb2 unless a commit is named.

- **Authorization identity.** `current_duz` is nil unless the token is a browser SSO token (`smart_authentication.rb:416-425`). That covers system tokens, and also any non-browser user or patient token.
- **Connection.** `RpcSupport.broker` wraps `BackendRegistry.current.client`, which is the process-global `RpmsRpc.client` (`rpc_support.rb:34-35`, `backend_registry.rb:140`). Nothing selects a connection by token or by application.
- **Most calls skip that wrapper.** Gateways mostly call `RpmsRpc::*` directly (for example `condition_gateway.rb:34`, `patient_gateway.rb:10-26`), so the audit wrapper is not on those paths, as ADR 0007 already records. `RpcSupport.broker` appears at 17 sites.
- **Count.** ADR 0008 counted 87 direct calls at 168ad00 (its 43-file figure does not reproduce; 25 files). The same grep (`RpmsRpc::<Module>.<method>` in `app` and `lib`, comments excluded) gives 81 at 966bd486 and 82 at 570c8cb2. Five of the 82 are `RpmsRpc::FilemanDateParser`, a pure parser with no client, so about 77 calls resolve the global client.
- **So** the RPMS-side identity of a system read is whatever the global client is signed on as. ADR 0011 describes the CIA case as the last clinician to sign in. That case was not re-measured.
- **The binding.** `oauth_applications.organization_id` is a free-form string column. It is blank-checked at mint (`backend_services_controller.rb:62`) and read by the interim guard (`:285-290`). Nothing else reads it.
- **The interim guard** refuses to mint once a second distinct organization is registered. It compares `strip.downcase` strings, not endpoints, so two labels that point at one broker would not trip it.
- **Boot can already fail open.** `configure_rpms_broker!` returns without configuring anything if a client is already set (`engine.rb:61`), and boots with no backend on a blank host (`:63-66`). The test helper presets a client.

## Decision

1. **Tenant and instance are one to one.** Each tenant has exactly one *active* instance, and each instance is active for exactly one tenant. An entity that runs two live instances is two tenants. A move between instances is not that case; see decision 7.
2. **Instance identity is the full connection key, validated at configuration load.** The key is the broker kind, the host resolved to its addresses, the port and, where one applies, the namespace. Configuration load fails when:
   - two tenants name the same instance, or two instance identifiers have the same key, including by DNS alias;
   - a tenant has no active instance, or more than one;
   - an enabled connection belongs to no tenant;
   - the topology cannot be established at all (see decision 8).

   Host and port are not proof of identity: a proxy, a load balancer or a second listener in front of one instance gives two keys for one instance. The key catches the careless case, and decision 3 is the backstop for the rest.
3. **A runtime attestation check is required, not optional.** At sign-on of a service account the connection must report which site it is signed on to, and the app compares that against the instance identity configured for the tenant. A mismatch refuses the connection and records a security event. Without it, two tenants whose endpoints are swapped (A to B's, B to A's) pass every load-time check.
   - A stock path exists: `RpmsRpc::Site.current` wraps `BEHOSICX SITEINFO` (rpms-rpc `lib/rpms_rpc/api/site.rb`) and `SiteGateway` already calls it. We write no M.
   - **Caveat, to be settled before this ADR is Accepted.** SITEINFO reports the signed-on site (division). Whether that yields a station key that identifies an instance, or only a division name, is unverified. If it cannot identify the instance, this decision names the stock RPC that can, or the ADR returns to the maintainer. It does not ship as a comparison that proves nothing.
4. **A system token runs on its tenant's connection as a named service account.** The client's registration gives the tenant (ADR 0008 binds it), the tenant gives the instance, and the session is the **backend client's** service account on that instance (ADR 0011 section 6: one account per backend client). The account is provisioned on that instance only, with credentials from host secrets. With no account configured the request gets 503. It never runs on a clinician's session and never reaches another tenant's instance.
   - The RPMS keys of each account are the ceiling on what its own client can do; scopes only narrow them. A tenant's total exposure is the union across its clients' accounts.
   - Jobs follow ADR 0012 rule 8. A job carries its tenant id from enqueue, runs on that tenant's connection under the service account configured for the tenant's jobs, and fails when none is configured. It never defaults to the process client.
   - Blast radius: a stolen service-account credential is a stolen account on one tenant's instance and no other. Least-privilege keys and rotation are the controls; neither is new to this ADR.
5. **Divisions never separate tenants.** A second division on an instance belongs to the same tenant. Of ADR 0007's division machinery:
   - **kept**, as mis-map detection (rpms-rpc#293): enumerate divisions at startup; fail closed on a division that maps to no tenant; capture the signed-on `DUZ(2)` and refuse one not allowlisted for the token's tenant;
   - **retired**: `(tenant, instance, division)` as a configuration triple that partitions tenants. Configuration is `(tenant, instance)`, and the division allowlist is an attribute of the tenant.
6. **The runtime property: no tenant request reads through an unscoped client.** In any process that serves a tenant, a read that does not carry a client bound to that tenant's connection is refused. A boot check alone does not give this: an implementer could dedupe endpoints while leaving `RpmsRpc.client` and the ~77 direct sites unchanged, and the identity of a request would remain "last clinician." This ADR requires the property and does not pick the mechanism. ADR 0008 option B (fiber-local `with_client`, `require_scoped_client`, off by default today) and ADR 0011 (explicit `BrokerSession`, ambient fiber-local rejected) answer the same question differently, and they must be reconciled before implementation. This is an open item, listed below.
7. **Who may change the mapping, and what a move is.**
   - The tenant-to-instance mapping is operator-held deployment configuration. Changing it is a privileged change: it takes effect at boot only, needs a review by someone other than its author, and writes a security event that records the old and new value, who changed it and when. A mapping change that nobody reviewed or logged is itself an incident.
   - A cutover (for example IRIS to YottaDB) is a change of a tenant's active instance, not a second tenant. The tenant keeps its record, its `organization_id` and its stamped rows; the old instance is marked retired in the same change, so a tenant never has two active instances. A dual-run period uses the retired instance read-only, and it is held out of decision 2's uniqueness test only while marked retired.
8. **Boot does not fail open.** Topology validation runs regardless of whether a client was already set and regardless of a blank host. In a deployed environment, a pre-injected client or a blank host with tenants configured is a boot failure. The test helper's preset client is permitted only under the test environment.
9. **Audit.** Every system read records the tenant, the instance, the service-account DUZ, the client application and the request id. Security events: a refused attempt to reach another tenant, an attestation mismatch, and every mapping change.
10. **What stays from ADR 0007 and ADR 0008.** The tenant record with `organization_id` as an immutable foreign key, the scoped client of ADR 0008 option B or its reconciled successor, and `tenant_id` stamping on locally held rows, cache keys, jobs and audit rows. Stamping is now needed before a second tenant shares a **process or database**, not before one shares an instance, because one process or database can serve several tenants even when no RPMS instance is shared. The `organization_id` string column is backfilled into the tenant record by ADR 0008 step 1, and the request context's `organization` (ADR 0012) resolves to the tenant through that foreign key.
11. **The interim guard is replaced by decision 2.** It is removed when the scoped client is live, as ADR 0007 already says. A sandbox instance is a tenant with its own instance and is not blocked by the guard once it is gone.

## Acceptance test

Two tenants, each with its own mock instance, with patients whose DFNs overlap:

- A token for tenant A that asks for tenant B's patient is refused. The test asserts that the DFN exists on B, and that the call reached A's client; it does not rest on the HTTP status, which a correct 404 and a broken route to B both produce.
- Registering both tenants on one endpoint fails load. So do a DNS alias, a second port on the same host and namespace, and two instance identifiers with one key.
- Swapping the endpoints of A and B is refused at sign-on by the attestation check (decision 3).
- A tenant with no service account gets 503 and never falls back to a user session. A job for a tenant with none fails and does not run on the process client.
- Boot with a pre-injected client or a blank host and tenants configured fails outside the test environment.
- An unreviewed or unlogged mapping change is detected and recorded as a security event.
- A tenant request issued through the global client with scoping on is refused (decision 6).
- Break each check on purpose and confirm the test goes red. An unverified gate is a comfort, not a control.

## Consequences

- A tenant record must exist before any of this is built (ADR 0007), and the configuration needs a place for the tenant-to-instance mapping. It is operator-held deployment configuration, never a client-registration field.
- ADR 0007's "several entities on one instance" branch becomes dead design. Its table of divergences loses one row.
- A sandbox or test instance of an entity is a separate tenant. Any state shared between them is cross-tenant state and is treated as such.
- Onboarding a tenant includes provisioning a service account for each backend client and one for its jobs. That is a site task (L3), not an engineering one.
- A tenant on a retired instance during a cutover is allowed only for the dual-run period.

## Alternatives rejected

**Support shared instances with row scoping** (the path ADR 0007 left open). The boundary would be derived from RPMS data that carries no tenant, so a single missed filter is a disclosure. The maintainer's position makes the case unsupported rather than merely hard.

**Tenancy is the instance, with no tenant record.** A deployment label is not stable across moves and migrations, which is the reason ADR 0007 kept the tenant first-class. That reasoning still holds, and decision 7 relies on it. The tenant record stays; it is only constrained to one active instance.

**Rely on the boot check alone.** Rejected because it protects a configuration and says nothing about which client a request used; see decision 6.

**Let a system token ride the shared client.** The state of the code today. It leaves the identity of a system read to whoever signed in last, and ADR 0011 section 6 already rejects it.

## Open items

- **Reconcile ADR 0008 option B with ADR 0011** on how a request gets its client (decision 6). Neither this ADR nor the review pass settles it.
- **Attestation key** (decision 3): whether SITEINFO or another stock RPC identifies an instance. Verify on a live build before Accepted.
- **Counsel.** The compliance premise, the breach classification, and how it interacts with 42 CFR Part 2 (ADR 0006).
- **rpms-rpc#293** (division detector) is still open; decision 5 relies on it.

## Not verified

- ADR 0011's last-clinician claim for system calls under CIA. Read from the ADR, not re-measured.
- Whether any real deployment has one entity on two instances, and what "two tenants" would mean for it.
- The ~77 figure is one grep on `main`; it excludes the pure parser and was not cross-checked another way.
