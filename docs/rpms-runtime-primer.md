# How RPMS works, from the database up

**For:** developers coming to RPMS from Ruby, Elixir or .NET.
**Status:** reference, 2026-10-30.
**Read next:** `docs/rpms-client-state-model.md` (what RPMS assumes about its clients) and `docs/identity-passthrough.md` (how a web user's identity reaches RPMS).

RPMS is the Indian Health Service's EHR, built on VA VistA.
Its language and its database are one system: code runs inside the database engine, and persistent data is a variable whose name starts with a caret.

## The stack

Read it bottom up.
Each layer talks to the one beneath it, and everything outside reaches in through a broker.

| Layer | What it is |
|---|---|
| Clients | VueCentric (Windows), BPRM (web, over SQL), lakeraven-ehr (web), PuTTY for terminal menus |
| Brokers | CIA, XWB and BMX listeners. Each connection gets its own M process. |
| Packages | AG registration, BSDX and SD scheduling, BMC referred care, OR orders, TIU notes, and many more |
| FileMan | The data dictionary, and the API for all data access: an ORM, written in M |
| Kernel | Users and sign-on, menus and options, security keys, background tasks, devices, the error log |
| M runtime + database | YottaDB or InterSystems IRIS: an M interpreter and the database, in one product |

## M, the language

M (also called MUMPS) dates from the late 1960s.
Programs are **routines**, files of **labels** that act as entry points.

```mumps
; call a label in another routine
 DO APPADD^BSDX07
; $$ calls a label that returns a value (an "extrinsic function")
 SET NAME=$$GET1^DIQ(44,"6,",.01)
; one data type: the string. Records are strings split on "^"
 SET X="MOUSE,MICKEY M^M^2100214"
 WRITE $PIECE(X,"^",2)   ; M
```

- **Variables are dynamically scoped.** A variable is visible to everything you call, unless the callee declares it with `NEW`. That is why `DUZ`, the current user, is simply there in every routine without being passed.
- **Commands abbreviate to one letter:** `S`et, `D`o, `Q`uit, `W`rite, `F`or, `I`f. Real code is dense.
- **Numbers are strings that look numeric.** There are no objects, structs or types.

*Ruby:* a module of methods called as `Module.method`, where every variable behaves like a global that a callee can shadow.

## Globals, the database

A **global** is a persistent, sparse, sorted, multi-dimensional array.
Setting one writes to disk, journaled and transactional.

```mumps
; a patient record, IEN 3, node 0, fields packed as pieces
 SET ^DPT(3,0)="MOUSE,MICKEY M^M^..."
; an index is just another subtree: name -> IEN
 SET ^DPT("B","MOUSE,MICKEY M",3)=""
; no queries: you walk sorted keys
 SET I=0 FOR  SET I=$ORDER(^DPT(I)) QUIT:'I  WRITE I,!
```

- `^DPT` holds patients, `^SC` clinics, `^BSDXAPPT` appointments, `^VA(200)` users.
- `^TMP($J)` is scratch space private to one process. `^XTMP` is scratch with an expiry date.

*Elixir:* an ordered ETS table that survives restarts and every process shares, closest to Mnesia.
*Ruby:* a nested `Hash` with sorted keys, stored on disk.

## Jobs, the runtime

Each connection or terminal session is an operating-system process running the M interpreter, called a **job**.
`$J` is its process id.
Every job shares the global database; local variables live only in the job.

- **When the job ends, its state goes:** local variables, `^TMP($J)`, and every `LOCK` it held. M locks are advisory and last as long as the process.
- **One request at a time per connection.** Concurrency comes from running more jobs.
- **Errors are trapped into `^%ZTER`,** the error log, with the job's local variables saved for inspection.

*Elixir:* a process per connection, except each one is a real OS process with no supervisor to restart it.
*.NET:* a stateful per-client session object, as in .NET Remoting or DCOM.
*Ruby:* closer to CGI, or a forking server with one long-lived worker per user.

## FileMan, the ORM and the schema

Every table is a numbered **file** and every column a numbered **field**.
The schema is itself stored as data, in `^DD`, the data dictionary.

```mumps
; file 44 HOSPITAL LOCATION, field 1918.5, read live from a 7c3119b build
 ^DD(44,1918.5,0)="SCHEDULE ON HOLIDAYS?^S^Y:YES;^SL;8"
;                  name                type codes  node;piece
; FileMan dates: year minus 1700, then MMDD, then .HHMM
 3261111       ; 2026-11-11
 3261111.0930  ; 2026-11-11 at 09:30
```

- **Files you will meet:** #2 PATIENT, #44 HOSPITAL LOCATION, #200 NEW PERSON, #19 OPTION, #19.1 SECURITY KEY, #8994 REMOTE PROCEDURE.
- **Entries are identified by IEN,** the internal entry number: a DFN for a patient, a DUZ for a user.
- **The API:** `UPDATE^DIE` creates, `FILE^DIE` updates, `GETS^DIQ` reads, `LIST^DIC` queries. The DDR RPCs expose these over the broker.
- **Go through FileMan, never set a global directly.** A direct set skips validation (input transforms), indexes (cross-references) and triggers.

*Rails:* ActiveRecord where `schema.rb`, the validations and the callbacks are all rows in a table.

## Kernel: identity, permissions and plumbing

- **Users** are entries in #200 NEW PERSON. A user's IEN is their `DUZ`. They sign on with an *access code* and a *verify code*, a username and password pair.
- **Options** (#19) are menu items. A menu option lists other options; a broker-context option lists the RPCs a client may call. A user has a primary menu and secondary menus, and the tree under them is what they may run. Kernel's one rule for "may this user run this option" is `$$ACCESS^XQCHK`.
- **Security keys** (#19.1) are named flags a user holds, such as `SDZSUP`, `AGZMENU` or `ORES`. A key can lock an option, or be checked inside code.
- **Division** is `DUZ(2)`, the facility the user is working in. **DTIME** is the user's idle timeout, in seconds.
- **TaskMan** runs background jobs on a schedule. **MailMan** is internal messaging. **Devices** are printers and terminals.

*Rails:* `current_user` is `DUZ`, set once at sign-on.
Keys are roles or claims.
TaskMan is Sidekiq or Oban; `^%ZTER` is Sentry.

## Packages and namespaces

Code is grouped into **packages**, each owning a two-to-four-letter **namespace** prefix on its routines, globals, options and keys.
It is a naming convention, not a module system: everything shares one namespace, so the prefix is how ownership is known.

| Prefix | Package |
|---|---|
| `XU` | Kernel |
| `DI` | FileMan |
| `AG` | Patient registration |
| `BSDX`, `SD` | Scheduling (Windows scheduling, and the scheduling core) |
| `BMC` | Referred care |
| `OR`, `TIU` | Orders, and clinical notes |
| `CIA` | The VueCentric framework and its broker |
| `LKR` | Lakeraven's own namespace |

## The RPC broker: how anything outside reaches in

**#8994 REMOTE PROCEDURE** maps an RPC name to an entry point and a reply type.
A **broker-context option** lists which RPCs a client may call while that option is bound.

```text
BSDX ADD NEW APPOINTMENT  ->  APPADD^BSDX07   (reply: global array)
BSDXRPC  "WINDOWS SCHEDULING PROCEDURE CALLS", 69 RPCs
```

A session runs like this:

1. The client connects. The listener starts a new job for it.
2. The client signs on. That sets `DUZ`, the division and the keys inside that job.
3. The client binds a context option.
4. It calls RPCs by name, with string and list parameters, and reads the replies.
5. It disconnects. The job logs the user out and ends.

**No RPC carries a user.**
Identity is whatever the job signed on as.
Whoever can write to a signed-on socket is that user, as far as RPMS can tell.
Every multi-user design decision for a web app follows from this.

Three protocols do the same job with different framing: **XWB** (the VistA standard), **CIA** (IHS, what VueCentric uses), and **BMX** (IHS, for .NET clients).

*.NET:* a SignalR hub with a server-side object per connection.
*Elixir:* a remote node where your connection is one process holding your identity.

## KIDS: packaging and migrations

The Kernel Installation and Distribution System ships changes as a **build**: routines, data-dictionary changes, data, options, RPCs, keys, and pre- and post-install routines, carried in a transport global.

- **Patch names** follow `NAMESPACE*VERSION*PATCH`, for example `LKR*1.0*1`. Install history lives in #9.6 and #9.7.
- **It changes a live database in place.** There is no automatic rollback; the safety net is a backup.
- **IHS and the VA ship everything this way.** rpms-ops builds each release image by installing the public KIDS patch ladder in order.

*Ruby:* a gem and a Rails migration in one artifact, applied to a running production database.

## The two engines

- **YottaDB:** open source, from the GT.M lineage, runs on Linux. The CIA broker listens on port 9100.
- **InterSystems IRIS:** commercial and licensed. It adds an SQL view of FileMan files (BPRM queries it over port 1972), a FHIR server and a management portal.
- The same M code runs on both, with small dialect differences. One example: YottaDB allows at most 32 arguments to a call.

## One booking, end to end

1. The web app's broker client connects, and the listener starts job 1234.
2. Sign-on sets `DUZ=208` (the demo scheduler), the division and the keys in job 1234.
3. The client binds `BSDXRPC` and calls `BSDX ADD NEW APPOINTMENT` with the patient, clinic, start, end and length.
4. The broker checks the RPC is in `BSDXRPC`, then runs `APPADD^BSDX07`.
5. That calls `$$MAKE^BSDAPI`, which files through FileMan into `^SC`, `^BSDXAPPT` and the patient's appointment list, firing their indexes and triggers.
6. The reply returns as rows of `^`-separated text, which the client parses.
7. If anything fails, the error and job 1234's variables are saved in `^%ZTER`.

## Your concepts, mapped

| You know | In RPMS |
|---|---|
| Postgres and Rails, as one system | The M runtime and globals: code runs inside the database |
| ActiveRecord, `schema.rb`, validations | FileMan, `^DD`, input transforms, cross-references |
| A table, and a row's id | A FileMan file number, and an IEN (DFN, DUZ) |
| An Elixir process per connection | One OS-level M job per broker connection, unsupervised |
| `current_user` | `DUZ`, set once at sign-on, dynamically scoped |
| Roles and claims | Security keys, plus options and the menu tree |
| An API endpoint | An RPC in #8994, allowed through a context option |
| A gem plus a migration | A KIDS build, named `NS*VER*PATCH` |
| Sidekiq or Oban | TaskMan |
| Sentry | `^%ZTER` |
| A module prefix | A package namespace: AG, BSDX, LKR |
