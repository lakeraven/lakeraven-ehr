# ADR 0008: A request reaches RPMS only through its tenant's client, and fails closed when it has none

**Status:** Accepted by the maintainer, 2026-10-17. Not yet through the gate (see "Decisions" below).
**Date:** 2026-10-17
**Decides:** the mechanism ADR 0007 left open for lakeraven-ehr#553.

## What this ADR is, and is not

ADR 0007 fixed the *meaning* of the tenancy boundary (the covered entity, a
first-class tenant record) and said enforcement is connection selection first,
with read scoping where tenants share an instance. It then named one choice and
left it to #553:

> Either the `RpmsRpc::*` modules must take an explicit client (or read one from
> a request-scoped context), or every gateway must route through the wrapper.

This ADR makes that choice. It does not redefine the tenant, design the tenant
table, or decide how divisions are detected (rpms-rpc#293). It does not restate
ADR 0007's decisions.

## What is true today (measured 2026-10-17 on `main` at 168ad00)

- **The binding is recorded and never read.** `oauth_applications.organization_id`
  is checked for blankness at mint time in `backend_services_controller.rb` and
  referenced nowhere else in `app/` or `lib/`.
- **There is one client.** `RpmsRpc.client` returns `configuration.client`, a
  single process-global (`rpms-rpc/lib/rpms_rpc/core.rb:51`). rpms-rpc has no
  fiber-local, thread-local or request-scoped client anywhere in `lib/`.
- **Most modules do not accept a client.** Of 40 modules under
  `rpms-rpc/lib/rpms_rpc/api/`, 4 have any method taking `client:` (9 methods in
  all, each defaulting to the global). The rest, `Problem` for example, read
  `RpmsRpc.client` inside the method body.
- **The EHR calls those modules directly.** `app/` and `lib/` hold 87 calls of
  the form `RpmsRpc::<Module>.<method>` across 43 files. None passes a client on
  the same line. `RpcSupport.broker` is not on these paths, so the audit wrapper
  and any binding attached to it are skipped (ADR 0007 already records this).
- **The request can name its application.** Controllers already read
  `current_token&.application` (`export_ownership.rb`, `auditable_clinical_access.rb`),
  so token to application to tenant is a lookup, not new plumbing.
- **A declared, opt-in control has failed here twice.** `patient_compartment.rb`
  records that binding was declared per action and that two review rounds found a
  door the declaration missed (`/Observation?patient=` in round 2,
  `/transitions_of_care` in round 3).

## Options

**A. Pass an explicit client to every module call.** Change the rpms-rpc
signatures so each method takes `client:`, and every EHR call passes it.
Cost: roughly 36 modules changed in rpms-rpc, 87 call sites in the EHR, and a
breaking gem release. Failure mode: the argument defaults to the global today.
Leave the default and a call that forgets `client:` silently uses the process
client and leaks across tenants. Remove the default and the failure becomes a
raise, but only after the whole migration lands. This is the shape that failed
twice in `patient_compartment`.

**B. A scoped client inside rpms-rpc, with a switch that makes "no scope" an
error.** Add `RpmsRpc.with_client(client) { ... }`, holding the client in
fiber-local storage, and make `RpmsRpc.client` return the scoped client when one
is set. Add a configuration flag, `require_scoped_client`. With it on,
`RpmsRpc.client` outside a scope raises instead of falling back to the global.
rpms-rpc has no Rails dependency, so this uses plain fiber-local storage, not
`ActiveSupport::CurrentAttributes`. The EHR wraps each authenticated request in
one `around_action` that resolves token to application to tenant to client (via
`SessionPool.with_client` or the tenant's own client) and calls `with_client`.
Cost: one method and one flag in rpms-rpc core, one concern in the EHR, and no
change to the 87 call sites. Failure mode: fails closed. A thread, fiber,
background job or console session that runs outside a scope raises
`NotConfiguredError`-style, and cannot read.

**C. Route every gateway through `RpcSupport.broker`.** Rejected without
costing it: the gateways call the `RpmsRpc::*` modules because those hold the
RPC names and parsers. Bypassing them means re-implementing 87 call sites'
worth of parsing in the EHR.

## Decision (recommended; the maintainer decides)

**Adopt B.** The deciding reason is the failure mode, not the size. A and C
leave "forgot to bind" as the default state, which is the exact defect #553
describes. B makes the default "no client, no read", and the control is one
place a reviewer can check, not 87.

Consequences to accept with it:

- **Scope does not cross threads.** Work handed to another thread, fiber or job
  runs unscoped and will raise. That is intended. Jobs already must carry
  `tenant_id` (ADR 0007), and now must also re-enter a scope.
- **rpms-rpc gains a public API.** `with_client` and `require_scoped_client` need
  a version bump and a note, and `require_scoped_client` stays off by default so
  existing hosts do not break on upgrade.
- **Tests that rely on the global client** (`RpmsRpc.mock!`) must either run
  inside a scope or run with the flag off. The flag is on in production config
  and in a dedicated test that proves an unscoped read raises.
- **It does not settle shared-instance tenants.** Two tenants on one instance
  need `tenant_id` on rows, caches and jobs as ADR 0007 says. B closes the
  connection half only.

## Sequence

1. **Tenant record and rename (EHR only, can start now).** Create the tenant
   table, make `organization_id` an immutable foreign key to it, backfill the one
   existing binding, and stop calling the tenancy concept "organization".
2. **Scoped client in rpms-rpc.** `with_client`, `require_scoped_client`, and a
   test that an unscoped call raises. Lands with or after #234's pool.
3. **Bind requests in the EHR.** The `around_action`, then turn the flag on.
   Un-skip the refusal test in #618 here, and reintroduce the gap to confirm the
   test goes red (SOFTWARE-FACTORY non-negotiable: verify the gate).
4. **Stamp `tenant_id`** on locally held clinical rows, cache keys, jobs and
   audit rows. Required before a second tenant shares an instance.
5. **Remove the interim guard** (#529's single-organization tripwire) once 3
   is live, as ADR 0007 states.

## Decisions (maintainer, 2026-10-17)

1. **Option B is adopted**: a scoped client in rpms-rpc with `require_scoped_client`, bound once per request in the EHR.
2. **December line:** steps 1 to 3 land before December; step 4 (tenant stamping) lands before any second tenant shares an instance.
3. **Gate level:** this is an authorization surface, so it goes through the hard panel (a spec seat other than the builder, two paid gate seats), not the volume panel.

The decisions were given as a one-word "ok" to the three questions this section previously asked. Acceptance is the maintainer's;
the ADR text itself has not yet been through the gate, so it should be gated before step 2 or 3 is built against it.

## Not verified here

- That `SessionPool` can be keyed by tenant for system tokens (it is keyed by an
  opaque session key today). ADR 0007's `(instance, division)` set is the input;
  the key shape is for #234.
- That every EHR entry point (controllers, jobs, rake tasks, console) can be
  wrapped by one `around_action`. Jobs and rake tasks are not request-shaped and
  need their own entry point.
