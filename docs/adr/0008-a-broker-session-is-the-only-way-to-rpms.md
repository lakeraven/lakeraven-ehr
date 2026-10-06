# ADR 0008: A broker session is the only way to reach RPMS, and a web process holds no shared identity

**Status:** Proposed
**Date:** 2026-10-06
**Implements:** #585 · **Builds on:** #539/#586 (CIA sign-on), rpms-rpc ADR 0005 (`SessionPool`), ADR 0006 (explicit clients), ADR 0010 (the consumer contract)
**Changes:** #553's single-organization guard, `AuthenticationService`'s wire mutex

## Context

RPMS ties identity to the broker connection.
Sign-on sets the M process's DUZ, context and keys, and every RPC on that socket runs as that user.

Today every RPC lakeraven-ehr sends goes through one process-wide `RpmsRpc.client`.
With #586 that client points at a live broker, which makes the defect real:

1. **Clinician to clinician.** User B signing in re-binds the shared connection.
   User A's next chart read runs as B. A sees what B may see, and the audit trail records B.
2. **System to clinician.** SMART backend-services requests (`system/` tokens) run under no user.
   They ride the shared client too, so they run as whichever clinician signed in last.
   No one chose that identity, so no policy decided it.
3. **The guards lean on the defect.** `AuthenticationService` serializes sign-on with a mutex whose own comment says it "narrows the window, it does not close it".
   #553's single-organization guard holds only *because* the client is shared.

#585 states the clinician's story: every RPC made for me runs under my own identity.
This ADR adds the system's half.
The application must not be *able* to send an RPC under an identity the request did not authenticate.
That should hold whether or not a developer remembers to, and it has to be built into the interface, not left to reviewers.

## Decision

### 1. No shared identity exists in a web process

The engine stops configuring `RpmsRpc.client` in the web server.
`config/rpms.yml` yields a **connection factory** (broker kind, host, port) that can make a fresh, unauthenticated client.
It never yields a client that anything shares.

The consequence is the guarantee.
Any code path that reaches for the global client, directly or through a gem module that resolves it internally, raises `RpmsRpc::NotConfiguredError`.
A forgotten session fails loudly in development and in tests.
It never quietly borrows another user's connection, because no such connection exists to borrow.

`RpmsRpc.client` stays for the console, rake tasks and jobs (rpms-rpc ADR 0005/0010), each of which signs on as a named identity of its own.

### 2. One door: `BrokerSession`

`Lakeraven::EHR::BrokerSession` is the only object through which request code reaches RPMS.
It holds the pool, the session's pool key, and the DUZ the session authenticated.
It never holds a checked-out client between calls (rpms-rpc ADR 0006, "Lifetime").

- **Construction is authenticated.** `current_broker_session` builds it from the authenticated request: a browser session, or a SMART token bound to that session.
  No public constructor takes a bare DUZ or key from params.
- **Every call is a short lease.** `session.call_rpc(...)` and `session.with_client { |c| ... }` check the client out through `SessionPool#with_client` for that call only.
  A multi-RPC sequence that must not interleave (sign-on, AGG registration, TIU create-then-sign) takes one lease around the whole sequence.
- **Identity is asserted on every checkout.** The leased client's `duz` must equal the session's DUZ, or the lease raises `BrokerIdentityMismatch`.
  That check costs one string comparison and no RPC.
  The session's client is then released and the browser session terminated.
  The pool already makes a mismatch structurally impossible, so this check guards against a bug in the pool itself.
- **`RpcSupport.broker` takes the session.** It becomes `RpcSupport.broker(session)` and wraps the session in `AuditedBroker`.
  The zero-argument accessor over the global is removed, so its 18 direct `call_rpc` sites cannot compile against the old shape.
- **Gem modules get the client explicitly.** `RpmsRpc::Patient.brief_header(dfn, client: c)` and the rest (rpms-rpc ADR 0006 option A).
  The gateways' existing `via:`/`default_provider` seam carries the session.

### 3. Sign-on never touches a shared client

`POST /login` asks the factory for a fresh client, signs it on with the user's own codes, reads its DUZ, and then `adopt`s it into the pool under a new key.
Sign-on is therefore isolated by construction: two simultaneous sign-ons use two sockets.
The wire mutex in `AuthenticationService` is deleted, because there is nothing shared left to serialize.

A refused sign-on disconnects its client.
A client is adopted only after the sign-on succeeds and is never re-authenticated in place.

### 4. The pool key is the session's credential, and it dies with it

The pool key is the browser session's SMART access-token id, which is minted at sign-on and is server-side.
One human holds one live browser token (`revoke_previous_tokens_for`), so one human holds one broker session per sign-on.

Every way a session ends releases its client, and `disconnect` sends the broker's quit, so the M process logs out:

- sign-out,
- the idle timeout,
- token expiry or revocation, including a new sign-in revoking the previous token,
- `terminate_session!`, which every sign-in attempt starts with.

This needs `SessionPool#release(key)` in rpms-rpc.
Today the pool evicts only by LRU or `shutdown`.

### 5. A miss means sign in again, never rebuild

The pool's `build` proc raises.
The app keeps no credentials, so it cannot sign on again on a user's behalf, and it must not try.
A request whose key has no client gets the sign-in page.
This covers a process restart, an eviction, or a request landing on another process.

That also states the process model.
The pool is per process, so a browser session is bound to the process holding its client.
Puma runs threads in one process (`test/dummy/config/puma.rb`, the #548 image).
Running several processes needs sticky sessions, and is a deploy decision recorded with it.

**Capacity fails closed.** When the pool is full of in-use clients, sign-in answers 503 with "RPMS is at capacity", and no existing client is reused.
`max_sessions` comes from `config/rpms.yml`.
Each slot is a long-lived M process on the RPMS host, so it is sized with the stack.

### 6. System access is a named identity, or none

A `system/` token gets a broker session for a **service account**: an RPMS user provisioned for that backend client, whose codes come from the host's secrets, never from a user.
That session is keyed to the client application, not to any human.
A deployment with no service account configured refuses `system/` requests with 503.
It never falls back to a clinician's session.

This replaces #553's structural argument ("one shared client, so one organization") with a stated one.
A backend client reaches the RPMS its service account signs on to, and nothing else.

### 7. The property is tested, not reviewed

- **Two-identity test:** two concurrent sessions, users A and B, each read through their own `BrokerSession`.
  Every RPC on A's lease runs on a client whose `duz` is A's.
  It runs against the mock in the suite and against the live container under `LIVE_RPMS=1`, with two seeded users.
- **No-global test:** booting the app in the server configuration leaves `RpmsRpc.configuration.client` nil, and calling a gateway with no session raises.
- **One-door test:** a test fails if `RpmsRpc.client`, `RpmsRpc.configure`, or a gem API module is referenced outside the adapter layer (`app/gateways`, `BrokerSession`, the console).
  New code cannot reopen the hole without breaking the build.
- **Lifecycle tests:** sign-out, idle timeout, token revocation and re-sign-in each leave the pool without the old key, and the old client disconnected.
- **Capacity test:** a full pool refuses sign-in with 503 and leaves every existing session's client untouched.

## Rollout

Two pull requests, in order.
Neither leaves a mixed state where a request path can still reach the global client.

1. **rpms-rpc:**
   - an optional `client:` keyword on `DataMapper`'s fetch helpers and on every API module that reaches `RpmsRpc.client` (about 30 references in 16 files on `92827ba`), defaulting to the global so other hosts keep working;
   - `SessionPool#release(key)`;
   - live specs for both.
   The keyword is optional in the gem because the guarantee comes from §1: the engine never configures the global client in a web process.
   Making it required everywhere is ADR 0010's later breaking release.
2. **lakeraven-ehr (#585):** §1-§7 on the new gem pin.

## Consequences

**Positive**

- Mixing up identities stops being a bug a reviewer has to catch and becomes something the process cannot do, because it holds nothing to mix up.
- Sign-on stops serializing, and RPC throughput scales with distinct sessions instead of queueing on one socket.
- The audit trail's user is the RPMS user who actually ran the RPC.

**Negative**

- Every gateway call site threads the session (25 files), a wide but mechanical diff.
- A process restart signs every user out.
  That is the honest consequence of holding no credentials.
- Backend services need an RPMS service account per deployment before `system/` tokens work against a live broker.

**Rejected**

- **Ambient fiber-local session** (rpms-rpc ADR 0006 option B): it relies on every path remembering to wrap, and threads lose the scope.
  §1 gives the same small diff at call sites with no silent fallback.
- **Key the pool by DUZ:** two sign-ins by one clinician would share a socket, and a sign-out couldn't release just one of them.
- **Re-authenticate a pooled client per request:** this is the #234 hazard in another form, and it needs stored credentials.
