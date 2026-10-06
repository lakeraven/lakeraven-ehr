# What RPMS assumes about its clients: state, identity, and the web

**Status:** reference, 2026-10-06.
**Read with:** ADR 0008 (a broker session is the only way to RPMS), rpms-rpc ADR 0005, 0006 and 0010.
**Evidence:** FOIA RPMS source (`~/workspace/FOIA-RPMS/Packages`) and the BPRM 4.0 p6 source (`GUI Source/bprm0400.06src.zip`), cited by file and line.
Claims marked *unverified* come from reading code, not from a run.

## Summary

RPMS was built for a thick client: one person at one workstation, holding one long-lived socket.
Every assumption below follows from that.
A web application breaks it at four points:

- many users share one server;
- each request is independent;
- any process may answer any request;
- every request comes from the same IP address.

The web tier has to bridge that gap on purpose, and the bridge has to be built into the design.
Developers can't be expected to remember it.

The short version of the recommendation:

- **Browser ↔ web tier:** a standard web session (HttpOnly cookie, the OAuth "backend for frontend" pattern). JWT access tokens are reserved for third-party API clients, where the party that issues a token is not the party that verifies it.
- **Web tier ↔ RPMS:** one signed-on broker connection per user session, bound at sign-on and never re-bound (ADR 0008). It's stateful because RPMS is.
- **Later, if wanted:** a stateless identity path into RPMS (a signed assertion that M itself verifies on each call). That is build work in rpms-ops, not something the web tier can invent.

## 1. The assumptions RPMS makes about a client

### 1.1 A connection is a process, and the process is the session

Each broker connection gets its own M job.
The XWB listener starts a job per connect (`NEWJOB^XWBTCPM`, `XWBTCPM.m:64,89`).
The CIA listener runs a dedicated secondary listener per client (`EN^CIANBLIS`, modes 1 and 2, `CIANBLIS.m:5-12`).
Everything the server knows about the session lives in that job's memory (its local symbol table), plus a few job-keyed globals.
When the socket closes, the job logs the user out (`LOGOUT^XUSRB` from `CIANBLIS.m:28`) and ends.

### 1.2 Identity is set once, at sign-on, and every call relies on it

Sign-on sets the job's identity: `DUZ` (the user), `DUZ(0)` (the FileMan access code) and `DUZ(2)` (the division), and through them the user's security keys (`AUTH^CIANBRPC`, `CIANBRPC.m:22-46`).
After that, an RPC request is just a name and its parameters.
**No request carries a user.**
The broker's only permission check, `CANRUN`, reads the job's own `DUZ` and current context (`Q:'$G(DUZ)!'RPC 0`, `CIANBACT.m:137`).

The consequence: whoever can write to a signed-on socket *is* that user, as far as RPMS can tell.

### 1.3 More than identity lives in the connection

| State | Where it lives | Set by |
|---|---|---|
| user, FileMan access, division | job locals `DUZ`, `DUZ(0)`, `DUZ(2)` | sign-on; `CIANBRPC DIVSET` |
| which RPCs are allowed (application context) | `CIA("CTX")`; `^XTMP("CIA",UID,"C",...)` | context selection (`BLDCTX^CIANBACT`, `CIANBACT.m:140-151`) |
| CIA session record | `^XTMP("CIA",UID)` (DUZ, context, job) | sign-on (`CIANBRPC.m:50-59`) |
| intermediate results | `^TMP($J,...)`, `^UTILITY($J,...)` | multi-step RPCs |
| locks | M `LOCK`s held by the job | e.g. order and note editing |
| asynchronous work | `^XTMP("CIA",UID,"T",...)` → TaskMan | async RPCs (`CIANBACT.m:55-60`) |

Some sequences only work if every step runs on the same connection: sign-on, context, then calls; create a note, then sign it; lock, edit, unlock.

### 1.4 One request at a time, per connection

The protocol is synchronous request/reply on one socket.
Concurrency comes from opening more connections, and each one is another job and another sign-on.

### 1.5 The client's IP stands in for the workstation

- **Failed sign-ons are counted per client IP**, and the device locks when the count reaches the limit (`FAIL^XUS3`, `XUS3.m:83-88`).
- **The sign-on log records the device and IP.**
- **Kernel's sign-on handoff token** (`XUS GET TOKEN`, `"~1"` handle) is single-use, valid for 20 seconds, and **refused from a different IP** (`CHECK^XUSRB4`, `XUSRB4.m:71-91`).
- **CIA's callback model** has the server dial back to the client's address, which assumes the client sits on a reachable workstation.

### 1.6 Credentials are protected by obfuscation and by the network

Access and verify codes travel through `XUSRB1`'s cipher: substitution with fixed tables shipped in the routine, so no secret key.
The brokers speak plaintext (cloud-rpms ADR-0027 keeps them inside the VPC).
RPMS assumes the network between client and server is trusted.

### 1.7 The session survives a dropped socket, but only for the same user

A CIA client that reconnects can rejoin its `^XTMP("CIA",UID)` session only by signing on again as the same DUZ.
Any other user gets error 27 (`CIANBRPC.m:50-55`).
There is no way to resume a session without credentials, beyond the 20-second handoff token in 1.5.

### 1.8 The other ways in

- **BMW SQL** (SuperServer, port 1972), which BPRM uses: one database account for every user. The app writes the user onto a borrowed connection with a stored procedure (`Core_SetSessionVariables`: `K DUZ`, then `S DUZ=+UserIen`, `DUZ(0)`, `DUZ(2)`). See §3.
- **FHIR on IRIS for Health:** stateless HTTP with OAuth bearer tokens. It exists only on IRIS stacks, and it covers reads more than the full RPC surface.

## 2. What changes for a web-based client

Each row is a place where the thick-client assumption fails, and what the web tier owes in its place.

| RPMS assumes | A web app has | So the web tier must |
|---|---|---|
| one user per process | many users per server process | never share a signed-on connection; bind one per user session (ADR 0008 §2) |
| identity set once, at the door | each request stands alone | bind identity when the connection is created; never stamp a user onto a shared connection later (§3 shows why) |
| the session is a long-lived socket | requests may land on any process; processes restart | send each session's requests to the process holding its connection (sticky sessions), or sign the user in again when it's gone; never rebuild a connection from stored credentials |
| one request at a time | tabs, parallel fetches, background refresh | serialize per connection (the client's wire lock); open a second connection only with the 20-second handoff token, never with stored codes |
| multi-step sequences on one socket | each request is independent | hold one lease for the whole sequence, within one request |
| the client IP is the workstation | every user arrives from the web server's IP | (a) throttle per account at the web tier before RPMS sees the attempt, or one attacker locks out every clinician (the sessions controller already does); (b) record the real browser IP in our audit, since RPMS's log will only show the server; (c) expect the handoff token's IP check to see the server's IP |
| sign-off ends the job | sessions end by idle timeout, revocation, browser close | release and disconnect the user's connection on every way a session ends; keep the web idle timeout the one that fires first (open question 2) |
| a trusted network | the public internet between browser and server | TLS on the browser side; keep the broker inside the VPC; codes reach RPMS only at sign-on and are never stored |
| one person, one workstation, at a time | jobs, websockets, API clients with no person | give each non-human caller a named RPMS identity (a service account) or no access, never a person's connection |
| RPMS's own audit | two audit trails, ours and RPMS's | store the CIA session UID (in the `AUTH` reply, `CIANBRPC.m:61`) with our session and audit rows, so either trail leads to the other |
| division chosen in the client | a division in a request | change division only through `CIANBRPC DIVSET` on the user's own connection; never accept it from a header or parameter |
| capacity sized for workstations | users in the hundreds | each signed-on user costs one M job; size the pool with the RPMS host, and refuse sign-in when it's full rather than share |

## 3. Precedent: how BPRM bridges the gap, and what to copy or avoid

BPRM 4.0 is a Blazor WebAssembly app: the UI and its state run in the browser.
Its server is a stateless ASP.NET Core API that reads a JWT on every request (`Server/UnitOfWork.cs`, `BeginAsync`: the DUZ comes from the `NameId` claim, the tenant from `tid`).
It reaches RPMS through BMW SQL, using a pool of connections that share one IRIS account, and writes the user onto each borrowed connection.

**Worth copying**

- Identity re-presented on every request, from a signed token, so any server process can answer.
- Identity set in one pipeline step (`SessionVariablesBehavior`), inside the same transaction as the work, rather than in every handler.
- The stored procedure clears the previous user before setting the next (`D ^XBFMK`, `K DUZ`).

**Worth avoiding** (from source, *unverified at runtime*)

- **The step that sets the user runs only for writes.** `SessionVariablesBehavior` is constrained to `TResponse : CommandResult`. Queries skip it, and only two query handlers set the user themselves (`IncompleteChart*QueryHandler.cs`). A read can therefore run with whatever `DUZ` the connection's last write left.
- **Nothing clears the user when a connection returns to the pool.** BPRM's own pool (`Server/Pooling.cs`, `Return`) checks only that the connection is open. The shipped default (`EnhancedPool: false`) uses the driver's pool with `Connection Reset=true`, and whether that clears M variables is untested.
- **The division comes from the client.** `DUZ(2)` is read from the `X-FACILITY-ID` request header, and the check for a missing header is commented out.
- **The sensitive-patient pipeline step is empty.** `SensitivePatientTrackingBehavior` contains `// check security token` and calls `next()`.
- **The database account is a superuser** (`_SYSTEM`), so IRIS privileges add nothing.

The pattern behind all five: BPRM decides in the app who the request is, then *tells* RPMS by stamping a shared connection.
Every gap is a place where the stamp is missing, stale, or supplied by the client.

**Blazor itself.** WebAssembly is what lets BPRM's server stay stateless.
Blazor *Server* keeps a per-user circuit in server memory, needs sticky sessions, and loses state on restart.
Its well-known footgun is per-user state registered as a singleton and leaking across users, which is exactly what a process-global `RpmsRpc.client` is.

## 4. Where JWTs fit, from first principles

### What a JWT is

A JWT (RFC 7519) is a signed set of claims: *the issuer says this subject has these attributes until this time, for this audience.*
Its value is that a party can verify the claims **without asking the issuer**.
That is what it's for, and it's also its main limit: a JWT can't be revoked before it expires unless the verifier checks back with the issuer, which brings back the shared state the JWT avoided.

Two questions are easy to conflate, and they have different answers.

### Question 1: how does the browser prove who it is to our server?

Our server both issues and verifies here, so a JWT's main benefit (verification without the issuer) buys nothing.
The current standards guidance for browser apps (IETF *OAuth 2.0 for Browser-Based Applications*) recommends the **backend-for-frontend (BFF)** pattern:

- The browser holds only a session cookie: `Secure`, `HttpOnly`, `SameSite=Lax` or `Strict`. Script can't read it, so cross-site scripting can't steal it.
- Tokens, and here the RPMS connection, stay on the server.
- Cross-site request forgery is handled by `SameSite` plus Rails' authenticity token.
- Revocation is immediate: delete the server-side session.

lakeraven-ehr's browser sign-in already works this way: an encrypted Rails session cookie, with the SMART token minted server-side and bound to that session.
Rule: **no bearer token in browser storage** (`localStorage` or `sessionStorage`).

### Question 2: how do other systems call our API?

SMART on FHIR apps, backend services and other partners need a credential they can carry, and our server isn't their session holder.
JWTs fit here:

- **OAuth 2.0 access tokens in the JWT profile** (RFC 9068), short-lived, with `aud` set to our API;
- **`private_key_jwt` client assertions** (RFC 7523) for backend services, which SMART Backend Services already uses;
- **sender-constrained tokens** (DPoP, RFC 9449, or mutual TLS, RFC 8705), so a stolen token is useless without the client's key.

Verification rules: pin the algorithm (no `alg: none`, no switching between RSA and HMAC), check `iss`, `aud`, `exp` and `nbf`, keep lifetimes short (minutes), and look up the server-side revocation record for anything that grants clinical access.

### Question 3: how does our server tell RPMS who is asking?

This is the hop where a JWT would matter most, and today it can't help.
The brokers can't verify a JWT: identity comes from the connection (1.2).
Three honest options:

1. **A stateful connection per user** (ADR 0008). It works with RPMS as built, and it's what VueCentric does.
2. **A shared connection the app stamps** (BPRM's pattern). This is the source of every gap in §3. Rejected.
3. **A stateless identity path in RPMS.** One broker entry point accepts a signed assertion per call (a JWT from our server, or an OAuth token-exchange result, RFC 8693, with an "acting on behalf of" claim). M verifies the signature, audience and expiry, sets `DUZ` for that call only, and clears it after. The connection authenticates the *web tier* (a proxy account limited to that entry point, ideally over mutual TLS); the assertion names the *user*. This is the standard trusted-subsystem-with-delegation pattern. It would let RPMS identify the user on each call, and it removes sticky sessions and the one-job-per-user cost. It is a change to RPMS's security model and needs:
   - JWT verification in M on both engines (IRIS has OAuth and JWT classes; YottaDB has none);
   - key management;
   - a review against Kernel's sign-on, audit and lockout behavior.

   It belongs in rpms-ops as build work, KIDS first.

### Recommendation

- **Now:** BFF sessions for browsers, JWT-profile OAuth for API clients, and ADR 0008's per-user connection to RPMS. Each uses the mechanism the standards intend for that hop.
- **Next:** open the design question for option 3 in rpms-ops, starting with whether IHS has, or would accept, a delegated-identity entry point.
- **Always:**
  - identity is bound at the hop where it's verified;
  - it's carried explicitly to the next hop, never taken from ambient state or from client input;
  - every hop fails closed when identity is missing.

## 5. Open questions

1. Does the IRIS driver's pool, with `Connection Reset=true`, clear M variables between borrowers? The test was attempted on iris-0929 on 2026-10-06 and blocked by an expired IRIS license.
2. Does the broker end an idle connection, and after how long? Not traced: neither CIA listener routine names an idle timeout. Whatever the answer, our idle timeout should end the session first and release the connection itself.
3. Which RPC sequences hold locks or `^TMP($J)` state across calls? Each needs one lease for the whole sequence. rpms-rpc ADR 0006 names sign-on, AGG registration, DDR filing, and TIU create-then-sign.
4. Is there an IHS position on delegated identity (option 3), or prior art in the VA's Broker Security Enhancement work?
