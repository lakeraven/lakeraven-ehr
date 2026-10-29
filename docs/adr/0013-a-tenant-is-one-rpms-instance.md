# ADR 0013: A tenant is exactly one RPMS instance, and an instance is never shared between tenants

**Status:** Proposed. The maintainer's position below was given on 2026-10-29. Revised after two rounds of adversarial review (Fable twice, Composer once; all on PR #734). The maintainer chose the client mechanism and the handling of instance copies on 2026-10-29 (decisions 3 and 6); the compliance premise still needs counsel before it can be Accepted. The compliance premise has not been reviewed by counsel.
**Date:** 2026-10-29
**Amends:** ADR 0007 (decision 1's "one instance may serve several entities", its rejection of "tenancy = the RPMS instance", and the partitioning role of its division machinery) and ADR 0008 (its "does not settle shared-instance tenants", the trigger for sequence step 4, and, **superseded here**, its choice of option B as the client mechanism; see decision 6).
**Builds on:** ADR 0011 section 6 (a system token runs as a named service account), ADR 0012 (the request context carries the tenant), lakeraven-ehr#553.

## Context

ADR 0007 made the tenant the covered entity and let the covered entity and the RPMS instance diverge in both directions: one entity on several instances, and several entities on one instance. Because of the second case it required read scoping and `tenant_id` stamping as well as connection selection, and it rejected "tenancy = the instance" for being unable to represent two entities on one instance.

The maintainer's position is that an organization is one RPMS instance, and that two covered entities sharing an instance is not a topology to support. A read under one entity's authority would reach another entity's patients, and the maintainer treats that as a breach. This ADR does not interpret HIPAA or classify any occurrence; that is for counsel. It takes the position as its premise.

The consequence for design is that a shared instance is an error state to refuse, not a case to engineer around. **Refusing it at configuration load is necessary and not sufficient.** A boot check on a topology does nothing about the runtime identity of a request, so this ADR also states the runtime property the check protects (decision 6).

## What a system token does today

Measured on `main` at 570c8cb2 unless a commit is named.

- **Authorization identity.** `current_duz` is nil unless the token is a browser SSO token (`smart_authentication.rb:416-425`). That covers system tokens, and also any non-browser user or patient token.
- **Connection.** `RpcSupport.broker` wraps `BackendRegistry.current.client`, which is the process-global `RpmsRpc.client` (`rpc_support.rb:34-35`, `backend_registry.rb:140`). Nothing selects a connection by token or by application.
- **Most calls skip that wrapper.** Gateways mostly call `RpmsRpc::*` directly (for example `condition_gateway.rb:34`, `patient_gateway.rb:10-26`), so the audit wrapper is not on those paths, as ADR 0007 already records. `RpcSupport.broker` has 16 call sites.
- **Count.** ADR 0008's "87 direct calls" counts matches of `RpmsRpc::<Module>.<method>` in `app` and `lib` **including comment lines** (87 at 168ad00; 82 at 570c8cb2). With full-line comments excluded the figure is 70 at 168ad00 and **50 at 570c8cb2**. Five of those 50 are `RpmsRpc::FilemanDateParser`, a pure parser with no client, so **about 45 call sites resolve the global client**. The earlier draft of this ADR said "about 77", repeating the comment-inclusive number under a claim that comments were excluded. 0008's "43 files" does not reproduce. The decisions below do not depend on the exact figure.
- **So** the RPMS-side identity of a system read is whatever the global client is signed on as. ADR 0011 describes the CIA case as the last clinician to sign in. That case was not re-measured.
- **The binding.** `oauth_applications.organization_id` is a free-form string column. It is blank-checked at mint (`backend_services_controller.rb:62`) and read by the interim guard (`:285-290`). Nothing else reads it.
- **The interim guard** refuses to mint once a second distinct organization is registered. It compares `strip.downcase` strings, not endpoints, so two labels that point at one broker would not trip it.
- **Boot can already fail open.** `configure_rpms_broker!` returns without configuring anything if a client is already set (`engine.rb:61`), and boots with no backend on a blank host (`:63-66`). The test helper presets a client.

## Decision

1. **Tenant and instance are one to one.** Each tenant has exactly one *active* instance, and each instance is active for exactly one tenant. An entity that runs two live instances is two tenants. A move between instances is not that case; see decision 7.
2. **The connection key is a uniqueness tripwire at configuration load. It is not the instance's identity.** ADR 0007 requires an instance identifier that is configuration-assigned and "not derived from a hostname, connection string or deployment name", and this ADR does not change that: identity stays the assigned identifier. The key (broker kind, host, resolved addresses, port, and namespace where one applies) is only used to refuse two identifiers that collide. Configuration load fails when:
   - two tenants name the same instance, or two instance identifiers have the same key, including by DNS alias;
   - a tenant has no active instance, or more than one;
   - an enabled connection belongs to no tenant;
   - the topology cannot be established at all (see decision 8).

   Resolved addresses can change under round-robin DNS without the instance changing, and a proxy, a load balancer or a second listener in front of one instance gives two keys for one instance. The key catches the careless case. It proves nothing about identity, and decision 3 is a partial backstop, not a proof.
3. **A runtime site check is required, and it is weaker than "attestation".** At sign-on of a service account the app compares what the connection reports about its site against what is configured for the tenant. A mismatch refuses the connection and records a security event. Without it, two tenants whose endpoints are swapped (A to B's, B to A's) pass every load-time check.
   - The stock path is `RpmsRpc::Site.current`, which wraps `BEHOSICX SITEINFO` (rpms-rpc `lib/rpms_rpc/api/site.rb`; `SiteGateway` already calls it). The RPC returns `^XMB("NETNAME")`, the station number and related fields of the signed-on `DUZ(2)`'s institution record, `DUZ(2)` itself, and `DUZ("AG")`. That is a **site key held in the database**. We write no M.
   - **What it cannot do.** A copy of an instance reports the same site key: a sandbox restored from production, or the YottaDB side of an IRIS to YottaDB cutover. So it catches a swap between two different sites and nothing between copies of one site. Decision 1 treats a sandbox as a separate tenant and decision 7 keeps a retired instance during dual-run; the site check cannot tell those instances apart. Separating copies needs something that differs per instance, and no stock source for that has been identified. **Maintainer decision 2026-10-29: keeping a sandbox, a retired instance and the live one apart is a deployment control, not something the software enforces.** The cutover and sandbox procedures must say so, and decision 7's dual-run rule rests on it.
   - **Not established from code:** whether `DUZ(2)` is set on a service-account sign-on. If it is not, SITEINFO's fields are mostly empty and the check has nothing to compare.
4. **A system token runs on its tenant's connection as a named service account.** The client's registration gives the tenant (ADR 0008 binds it), the tenant gives the instance, and the session is the **backend client's** service account on that instance (ADR 0011 section 6: one account per backend client). The account is provisioned on that instance only, with credentials from host secrets. With no account configured the request gets 503. It never runs on a clinician's session and never reaches another tenant's instance.
   - The RPMS keys of each account are the ceiling on what its own client can do; scopes only narrow them. A tenant's total exposure is the union across its clients' accounts.
   - Jobs follow ADR 0012 rule 8: a job stores its principal, scopes, request id and tenant at enqueue, and runs on that tenant's connection under a service account, acting on behalf of that principal. It fails when no account is configured. It never defaults to the process client. No job on main calls `RpmsRpc` today, so this binds future jobs only.
   - Blast radius: a stolen service-account credential is a stolen account on one tenant's instance and no other. Least-privilege keys and rotation are the controls; neither is new to this ADR.
5. **Divisions never separate tenants.** A second division on an instance belongs to the same tenant. Of ADR 0007's division machinery:
   - **kept**, as mis-map detection (rpms-rpc#293): enumerate divisions at startup; fail closed on a division that maps to no tenant; capture the signed-on `DUZ(2)` and refuse one not allowlisted for the token's tenant;
   - **retired**: `(tenant, instance, division)` as a configuration triple that partitions tenants. Configuration is `(tenant, instance)`, and the division allowlist is an attribute of the tenant.
6. **The runtime property: no tenant request reads through an unscoped client.** In any process that serves a tenant, a read that does not carry a client bound to that tenant's connection is refused. A boot check alone does not give this: an implementer could dedupe endpoints while leaving `RpmsRpc.client` and about 45 direct sites unchanged, and the identity of a request would remain "last clinician."
   - **Mechanism, chosen by the maintainer 2026-10-29: an explicit `BrokerSession`, passed as an argument** (ADR 0011, ADR 0012 rule 5). No ambient, fiber-local, thread-local or global client holds the tenant binding. The session is checked out per call through `SessionPool#with_client`, which exists in rpms-rpc at the pin.
   - **This supersedes ADR 0008 option B** (fiber-local `with_client`, `require_scoped_client`), which that ADR's maintainer acceptance of 2026-10-17 had chosen. ADR 0008 needs a follow-up edit to record that, and its sequence steps that build the fiber-local client and the flag are replaced by threading the session through the roughly 45 direct sites. The flag is not built.
   - **What replaces the flag.** A read that arrives without a session has nothing to fall back to: the process-global `RpmsRpc.client` is removed from web processes (ADR 0011 section 1), so the failure mode is "no client, no read." Until the direct sites are converted, the unconverted ones are the known exposure, and the acceptance test lists them.
7. **Who may change the mapping, and what a move is.**
   - The tenant-to-instance mapping is operator-held deployment configuration. **Software** can detect a change; it cannot know who edited it or whether it was reviewed. At boot the app compares the loaded mapping with the one it last recorded, and any difference writes a security event with the old and new value. The change takes effect at boot only.
   - Review by someone other than the author, and protection of the config source, are **process controls** of the deployment (for example branch protection). They are required, and they are not something an acceptance test can prove.
   - A cutover (for example IRIS to YottaDB) is a change of a tenant's active instance, not a second tenant. The tenant keeps its record, its `organization_id` and its stamped rows; the old instance is marked retired in the same change, so a tenant never has two active instances. During dual-run the retired instance is read-only and is not counted against decision 2's uniqueness test while marked retired. The site check in decision 3 cannot tell the retired copy from the new instance; the cutover procedure, not the software, keeps them apart.
8. **Boot does not fail open.** Topology validation runs regardless of whether a client was already set and regardless of a blank host. Outside the test environment, a pre-injected client or a blank host with tenants configured is a boot failure; development is not exempt, except for the spike mock that is explicitly gated as a spike (`test/dummy/config/initializers/zz_spike_mock_rpc.rb`). The test helper's preset client is permitted only under the test environment. Under ADR 0011 section 1 the engine no longer configures a global client in web processes; this decision then applies to whatever does configure one.
9. **Audit.** Every system read records the tenant, the instance, the service-account DUZ, the client application and the request id. Security events: a refused attempt to reach another tenant, an attestation mismatch, and every mapping change.
10. **What stays from ADR 0007 and ADR 0008.** The tenant record with `organization_id` as an immutable foreign key, the session-bound client of ADR 0011 (ADR 0008 option B is superseded by decision 6), and `tenant_id` stamping on locally held rows, cache keys, jobs and audit rows. Stamping is now needed before a second tenant shares a **process or database**, not before one shares an instance, because one process or database can serve several tenants even when no RPMS instance is shared. The `organization_id` string column is backfilled into the tenant record by ADR 0008 step 1, and the request context's `organization` (ADR 0012) resolves to the tenant through that foreign key.
11. **The interim guard is replaced by decision 2.** It is removed when the scoped client is live, as ADR 0007 already says. A sandbox instance is a tenant with its own instance and is not blocked by the guard once it is gone.

## Acceptance test

Two tenants, each with its own mock instance, with patients whose DFNs overlap. The assertions are written so each fails when its property is broken.

- **A cannot read B.** Set the process-global client to B's (or to one that raises) and send A's token for a patient that exists on both. The test asserts that the answer came from A's instance and that no call used the global client. It does not rest on a status code: with overlapping DFNs A's instance answers, and a correct refusal and a broken route look alike.
- **One endpoint fails load.** Run this against the real boot path, with DNS not stubbed: the same endpoint, a DNS alias, a second port on the same host and namespace, and two identifiers with one key.
- **A swap between different sites is refused at sign-on** by the site check (decision 3), using fixtures whose SITEINFO differs. This test does **not** claim to catch copies of one site, and it says so.
- **No account means 503 and no fallback.** Run it with a clinician signed in concurrently on the same process; without one, a fallback to a clinician session cannot show. A job for a tenant with no account fails and does not run on the process client.
- **Boot does not fail open.** Run it with the test-environment exception off, for a pre-injected client, a blank host with tenants configured, and zero tenants.
- **A changed mapping is detected.** Boot with a different mapping from the recorded one and assert the security event. (Review of the change is a process control and is not tested here.)
- **A read with no session is refused.** With the global client removed from the web process, a call that reaches RPMS without a session raises. The test enumerates the direct sites still unconverted and fails on any new one.
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

- **Record the supersession in ADR 0008** (decision 6) and convert the direct `RpmsRpc::*` sites to take a session. The mechanism is decided; the conversion is implementation.
- **Write the deployment procedure** that keeps sandbox, retired and live instances apart (decision 3), since the software cannot. Also check on a live build whether `DUZ(2)` is set on a service-account sign-on.
- **Counsel.** The compliance premise, the breach classification, and how it interacts with 42 CFR Part 2 (ADR 0006).
- **rpms-rpc#293** (division detector) is still open; decision 5 relies on it.

## Not verified

- ADR 0011's last-clinician claim for system calls under CIA. Read from the ADR, not re-measured.
- Whether any real deployment has one entity on two instances, and what "two tenants" would mean for it.
- The ~45 figure is a grep excluding full-line comments and the pure parser. It can still miss calls made through aliases or string dispatch.
