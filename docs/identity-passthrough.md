# Does RPMS see the right user? Identity from the browser to RPMS

**Status:** findings, 2026-10-30.
**Verified on:** a disposable local rpms-ydb container of `bcer-9.0-20261029-7c3119b-ydb`, using the demo users PROFILE,SCHED (DUZ 208) and PROFILE,REG (DUZ 207), and lakeraven-ehr `main` at `fc6fba2`.
**Read with:** `docs/rpms-client-state-model.md`, ADR 0011 (one broker session per user), ADR 0012 (identity and scope on every request), ADR 0010 (permissions from RPMS), #585.

## The short answer

- **One user signed in at a time:** yes. RPMS runs every RPC as the user who signed on, and its own checks apply to that user.
- **Two or more users signed in at once:** no. Every user shares one broker connection, and each sign-on re-binds it. RPMS runs everyone's RPCs as whoever signed on last, and records them under that user.
- **The application:** RPMS records lakeraven-ehr's sessions as VueCentric's (context `CIAV VUECENTRIC`), with no workstation name and no browser IP address.

So lakeraven-ehr is safe for one user at a time, and not yet for many.
The fix is designed (ADR 0011, #585) and not built.

## How identity reaches RPMS today

1. The engine configures one process-wide broker client at boot (`lib/lakeraven/ehr/engine.rb`, `RpmsRpc.configure`).
2. A user signs in at `POST /login`.
   `AuthenticationService#cia_signon` calls `authenticate` with the user's access and verify codes on that same shared client.
3. rpms-rpc sends `CIANBRPC AUTH` with two of its six parameters: the application ID, always `CIAV VUECENTRIC`, and the encrypted codes.
   It does not send the workstation ID, the NT security ID or the workstation IP.
4. RPMS signs the connection's M job on as that user.
   Sign-on sets `DUZ`, the division and the keys in that job, and every later RPC on the socket runs as that user.
5. The browser session stores the DUZ, keys and options that sign-on read, and the app authorizes screens from them (`Capabilities`, #754).

`AuthenticationService` serializes sign-ons with a mutex.
Its own comment says this "narrows the window, it does not close it": the mutex keeps two sign-ons from interleaving, but cannot stop the second from replacing the first.

## What we verified

The test signed on two users, one after the other, on one CIA client, as `AuthenticationService` does today:

```text
A signed on: duz=208 user=PROFILE,SCHED  CIA session 405
B signed on (same socket): duz=207 user=PROFILE,REG  CIA session 406
client now believes: duz=207
```

RPMS's sign-on log (#3.081) shows one M job, 115891, signed on as 208 and then as 207:

```text
3261030.160444    user=208 job=115891 signoff=  ip=[] ws=[]
3261030.16044401  user=208 job=115891 signoff=  ip=[] ws=[]
3261030.16044402  user=207 job=115891 signoff=  ip=[] ws=[]
3261030.16044403  user=207 job=115891 signoff=  ip=[] ws=[]
```

(This build writes two log rows per sign-on.)

- **The connection changed users without a sign-off.** RPMS never logged user 208 off; the same job simply became user 207.
- **Both CIA sessions record context 10979, `CIAV VUECENTRIC`** (`^XTMP("CIA",405,"C",10979)`, and the same for 406).
- **The IPv4 address (field 11) and workstation name (field 12) are empty** on every row.

## What follows from this

| Question | Today |
|---|---|
| With one user signed in, does RPMS run their RPCs as them? | Yes |
| With two users, does each user's RPC run as that user? | **No.** It runs as whoever signed on last |
| Does RPMS's audit name the real user? | Only with one user signed in |
| Do RPMS's own permission checks (option gate, keys inside RPCs, FileMan screens) apply to the right user? | Only with one user signed in |
| Does lakeraven-ehr's own audit row name the right user? | It names the browser session's user, which can differ from the user RPMS ran the RPC as |
| Can an RPMS record be traced to the web request? | No. The app stores neither the CIA session id nor RPMS's job number with its audit rows |
| Does RPMS know which application, workstation or browser IP the request came from? | No. It sees "VueCentric", no workstation, no IP |
| Do the app's screen permissions follow the user's RPMS keys? | Yes. They are read at sign-on for the signed-in user (#754) |

## What makes it right

In the order to build:

1. **One broker connection per signed-in user (ADR 0011, #585).**
   - Sign-on opens a fresh connection for the user and keeps it in a pool keyed by their session. It is never re-bound to another user.
   - Every request leases that user's connection, and checks the connection's DUZ matches the session's.
   - Sign-out, the idle limit and the 12-hour cap disconnect it, so RPMS logs the user off.
   - This is the precondition for every row in the table above.
2. **lakeraven-ehr's own application option.** A broker-context option in the `LKR` namespace, assigned by the site manager, so RPMS records "lakeraven-ehr" rather than "VueCentric". It also lets the site grant web access separately from Windows-client access. See the ADR 0010 discussion of `chart.read`.
3. **Pass the browser's address to sign-on.** `CIANBRPC AUTH` takes a workstation ID and a workstation IP. Sending the browser's IP, and a workstation ID naming lakeraven-ehr and the session, fills the sign-on log fields that are empty today. This needs an rpms-rpc change to `CiaClient#authenticate`.
4. **Link the two audit trails.** Store the CIA session id (from the `AUTH` reply) with the browser session and on every audit row, as ADR 0012 rule 12 says. Either trail then leads to the other.
5. **Expect the shared IP.** Every web user reaches RPMS from the app server's address. Kernel counts failed sign-ons per device, so the app throttles failed sign-ins per account before RPMS sees them (`LoginThrottle` does this). Kernel's MULTIPLE SIGN-ON setting (#200 field 200.04, site default in #8989.3) has an "only one IP" choice, which every web user would share. Read it on each site.

## Until then

Run lakeraven-ehr for **one signed-in user at a time** against any RPMS that matters.
The demo and the local development setups do.
A shared deployment with several users waits for #585.
