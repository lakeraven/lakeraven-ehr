# ADR 0010: What a user may do is derived from their RPMS options and keys, and carried as capabilities and SMART scopes

**Status:** Proposed
**Date:** 2026-10-23

> **Numbering.** Open PRs already use 0005, 0008 (twice) and 0009, so this ADR takes 0010.
> It builds on ADR 0009 in PR #594 (every request carries an identity and a scope), and fills one gap that ADR leaves open: where the scopes come from.

## Scope, and what this ADR deliberately is not

This ADR decides which RPMS facts a user's permissions are derived from, how those facts become what a token carries, and where they are enforced.
It does not design the broker connection (ADR 0008 in #594, rpms-rpc ADR 0005).
It does not design SSO or IdP provisioning (#531, #607); whatever signs the user on, the permissions are read the same way.
It does not decide record-level rules (Part 2, sensitive patients); those stay with ADR 0006, #494 and #613.

## Context

### What RPMS uses to say what a user may do

RPMS has no single permission concept.
Four things carry it, all stored in RPMS and maintained by site managers with Kernel's own tools:

| RPMS fact | Where | What it governs |
|---|---|---|
| **Options** on the user's menu tree | OPTION (#19); primary and secondary menus on NEW PERSON (#200) | Which applications and functions a user may run. A broker context is an option, and so is `CIAV VUECENTRIC`, the context the IHS EHR signs on under. |
| **Security keys** | SECURITY KEY (#19.1), held on #200 | Narrower rights: ordering role (`ORES`, `ORELSE`, `OREMAS`, `PROVIDER`), registration (`AGZMENU`, `AGZVIEWONLY`, `AGZVIEWSSN`), ADT (`DGZADT`), sensitive records (`DG SENSITIVITY`), scheduling supervision. A key can also lock an option. |
| **Division** | `DUZ(2)`, from the user's divisions on #200 | Defaults and per-division numbering (health record numbers). Not a visibility boundary for a known patient. |
| **Patient-level rules** | Sensitive and restricted records (DG SECURITY) | Whether *this* user may open *this* patient, with a warning and a log. |

Kernel decides option access with one rule, `$$ACCESS^XQCHK`: the option must be reachable from the user's primary or secondary menus, not out of order, and not locked by a key the user lacks (or reverse-locked by one they hold).
That is the rule the stock RPC broker applies to every call.

### What the two existing RPMS clients do

**VueCentric** (Windows) signs the user on with their access and verify codes, under the `CIAV VUECENTRIC` context, and binds DUZ and division to the broker session.
Which tabs and components a user sees is decided from the VueCentric object registry, where each object may require any one, or all, of a set of security keys.
Clinical actions are gated inside the RPCs by keys: the ordering role comes from `ORES`, `ORELSE`, `OREMAS` and `PROVIDER`, and note signing goes through TIU's business rules.

**BPRM** (web) also signs the user on with access and verify codes.
It reads the user's keys, secondary menus, primary menu and divisions, puts them in a JWT as claims, and expresses each permission as a claim requirement (for example "holds `AGZMENU` and not `AGZVIEWONLY`" to register a patient).
Those requirements are checked mostly in the browser (#600).

BPRM 4.0 (p6 source) defines about 30 such policies. The personas they imply are the front office's, and the keys are the ones IHS sites already assign:

| Persona BPRM implies | Keys and menus | What BPRM allows |
|---|---|---|
| Registration clerk | `AGZMENU` (or the `AGMENU`, `AGPAT` menus) | register (not with `AGZVIEWONLY`), edit demographics, view, reports |
| Registration manager | `AGZMGR` | edit HRN, change name, edit death information, registration tables |
| View only | `AGZVIEWONLY` | view and report; denies registering |
| SSN viewer | `AGZVIEWSSN` | see the whole SSN |
| Scheduler | `SDZMENU` (and `SDZ ELIG REPORT` from registration) | scheduling |
| Scheduler who mini-registers | `SDZREGMENU` | a short registration from scheduling |
| Scheduling supervisor | `SDZSUP` | all of scheduling, scheduling tables |
| ADT clerk, nurse | `DGZADT`, `DGZNUR` (`DGZMENU`, `DGZPCC` to open ADT) | admit, discharge, transfer; move patients |
| Incomplete chart, HIM | `DGZICE`, `DGZPCC` | incomplete chart tracking |
| ADT supervisor | `DGZSUP`, `DGZSYS` | ADT tables |
| Security officer | `DG SECURITY OFFICER` | sensitive-record functions |
| Record flags | `DGPF ASSIGNMENT`, `DGPF MANAGER` | assign flags; flag tables |
| Benefits | `AGZCREOPN` | reopen a benefits case |

The vocabulary is sound; the enforcement is not. The server checks only that a token is valid, the token carries raw key names, and `CanEditPatients` also accepts `XUPROG` and `XUPROGMODE`.
This app takes BPRM's catalog as the source of its front-office rows (Decision 1), and enforces each on the server.

Both clients derive permissions from the same two facts, options and keys.
Neither has a permission keyed by clinic, ward or institution.

### What lakeraven-ehr does today

`SessionScopePolicy` maps 13 names to SMART v1 scopes.
12 of them are not security keys on the built image; the chart-read entry, `OR CPRS GUI CHART`, is an option (#578).
The key read turns a failure into "no keys".
So every real sign-on today gets an empty scope string and can read no chart, and a broken read looks the same as a user with no rights.
A second model (`Roles`, `user_type` and the policies) sits beside the scopes and can disagree with them.

## Decision

### 1. One table, owned by this app, from RPMS facts to capabilities

The app keeps one table of **capabilities**.
A capability is a named thing a user may do (`chart.read`, `order.sign`, `patient.register`, `patient.ssn.view`).
Each row states its RPMS rule in RPMS terms:

- an **option** the user must have access to, by Kernel's rule; and/or
- **keys**, any one or all of a set (the VueCentric object registry's own "any / all" semantics); and optionally
- keys that **deny** it (BPRM's `AGZVIEWONLY`).

The same row says which SMART scopes the capability grants.
This table replaces `SessionScopePolicy::KEY_SCOPES`, `Roles.can?` and the gem's deprecated `can_*` helpers; there is one model, not two.

Initial rows (each name verified as an option or key on the pinned build):

| Capability | RPMS rule | Scopes |
|---|---|---|
| `chart.read` | option `CIAV VUECENTRIC` | `user/Patient.rs`, and read/search on the chart's clinical types |
| `order.enter` | any key `ORES`, `ORELSE`, `OREMAS` | (write scopes when CPOE writes land, #641) |
| `order.sign` | key `ORES` | (as above) |
| `registration.search` | any key `AGZMENU`, `AGZMGR`, `AGZVIEWONLY` (BPRM: CanAccessPatientProfile) | none: AG's own lookup |
| `registration.view` | any key `AGZMENU`, `AGZMGR`, `AGZVIEWONLY`, `SDZMENU`, `SDZSUP` (BPRM: CanViewPatient) | none |
| `patient.register` | any key `AGZMENU`, `AGZMGR`, denied by `AGZVIEWONLY` (BPRM: CanRegisterPatient, which takes `AGZMENU` only; `AGZMGR` edits patients there, so registers here) | `user/Patient.cu` |
| `scheduling.open` | any key `SDZMENU`, `SDZSUP` (BPRM: CanAccessScheduling) | none |
| `scheduling.supervise` | key `SDZSUP`: every resource, whatever its BSDX rights (BPRM: SchedulingSupervisor) | none |
| `patient.ssn.view` | key `AGZVIEWSSN` | none: a field rule, not a resource |
| `adt.move` | any key `DGZADT`, `DGZNUR`, `DGZSUP`, `DGZSYS` (BPRM: CanMovePatient) | `user/Encounter.cu` |
| `patient.sensitive.open` | key `DG SENSITIVITY` | none: input to the sensitive-patient check (#613) |

Chart read follows the option, not a key, because that is how an IHS site turns on EHR access: it gives the user the `CIAV VUECENTRIC` option.
A user without it can still sign on and see the dashboard, and is told they have no chart access.

### 2. The facts are read at sign-on, through rpms-rpc, and a failed read refuses the sign-on

After the user is authenticated, the app asks RPMS two questions, each through the rpms-rpc symbolic API, and asks for exactly the names the table uses:

- which of these keys the user holds (`Authentication.held_keys`, already in the pinned gem);
- which of these options the user may run, by Kernel's rule (a new rpms-rpc call, `ORWU HAS OPTION ACCESS`, which answers `$$ACCESS^XQCHK` for the signed-on user).

An answer of "could not ask" (`nil`) refuses the sign-on with a visible error.
It is never treated as "holds nothing".

The app applies Kernel's option rule itself, from these answers, on every request.
It does not leave that check to the broker alone: the answer is the app's own, the same whichever broker a deployment uses.
RPMS still checks again inside each RPC (ADR 0009 rule 7), so the app's capabilities only ever narrow what RPMS allows.

### 3. Capabilities become SMART scopes for FHIR, and are checked by name everywhere else

- A FHIR request is checked against SMART v2 scopes (`user/Observation.rs`), as ADR 0009 says.
- A non-FHIR action (register a patient, sign an order, view an SSN) is checked against the capability by name, on the server, in the controller or service that does it.
- The UI shows or hides controls from the same capability set, so what a user sees and what the server allows cannot drift. A hidden control is never the only check.

### 4. What a token carries

Following ADR 0009:

- **The browser** keeps a server-side session behind a cookie. The session holds the DUZ, the division, the capability set and the scopes. Nothing about the user's RPMS rights is sent to the browser except what the UI needs to render.
- **Third-party API clients** get RFC 9068 JWT access tokens: `sub` is the user, `fhirUser` their Practitioner, `scope` the SMART scopes their capabilities grant (narrowed to what the client was registered for and asked for), plus tenant and division claims.
- A token carries **capabilities and scopes, never raw key or menu names**. BPRM's tokens carry keys; ours do not. That way the server stays the authority, and a site's key structure is not published to every client.

### 5. Division, and why there are no clinic, ward or institution scopes

- The division is `DUZ(2)` from sign-on. It changes only to a division listed on the user's own #200 entry.
- RPMS has no permission that limits reading a known patient by clinic, ward or institution, so this app adds none. "Patients in my clinic" or "on my ward" is a list or filter in the UI, not an authorization rule.
- Patient lookup may follow RPMS's default of listing the patients registered at the signed-on division. That is a search default, not a boundary.
- Tenancy between organizations is ADR 0007's boundary, not a scope.

### 6. What scopes cannot express stays a per-read check

Opening a sensitive or restricted patient goes through RPMS's own sensitive-record check and log on every read path, not only at patient select (#613).
Part 2 content is segmented at the record level (ADR 0006, #494).
Neither becomes a scope.

### 7. Programmer access grants nothing extra

Programmer mode (`XUPROGMODE`) and FileMan programmer access (`DUZ(0)="@"`) never become capabilities or scopes.
A developer operator gets chart access the same way a clinician does: by holding the option.

### 8. Lifetime

- The capability set is fixed at sign-on and lives as long as the session. The session ends after the shorter of the user's RPMS idle limit (DTIME) and the site's (30 minutes by default), and 12 hours after sign-on however active (#747; NIST SP 800-63B-3 at AAL2).
- A change to a user's keys or menus in RPMS takes effect at their next sign-on. Revoking a user in RPMS ends their next request, because the per-user broker session (ADR 0008) fails.
- A verify code that RPMS has flagged as expired gives a session that can only change the verify code (#493).

## Alternatives considered

- **Keys only.** Rejected: RPMS does not use a key to grant chart access. The option is the fact a site manages, and `OR CPRS GUI CHART` in the current table is an option, which is why the table never matched a real user.
- **Rely on the broker's context check alone.** Rejected as the only control: two independent checks, the app's and RPMS's, are the posture ADR 0009 sets. The app applies Kernel's rule itself and RPMS checks again.
- **BPRM's model: keys and menus in the token, enforced in the browser.** Rejected: the server must enforce every capability (#600), and raw key names do not belong in tokens given to third parties.
- **Clinic, ward or institution scopes.** Rejected: RPMS has no such restriction for reading a chart, and inventing one would be a control with no RPMS fact behind it.

## Consequences

- **rpms-rpc** gains one read: which of these options the signed-on user may run (`ORWU HAS OPTION ACCESS`), returning `nil` when it could not ask. lakeraven-ehr moves its pin only after that merges.
- **lakeraven-ehr** (#578): the capability table replaces `SessionScopePolicy::KEY_SCOPES`, `Roles` and the `can_*` calls. Sign-on reads keys and options, fails closed on `nil`, and mints SMART v2 scopes. A test checks every name in the table against the pinned build's registry.
- **Sites, and the demo builds,** give EHR users the `CIAV VUECENTRIC` option, as an IHS site does for VueCentric users. On the current demo builds no seeded user has it, so until the seeds change, no one can read a chart through this app. That is the correct answer for those users, and the seed change is build work.
- **An application-level test** signs on as each seeded persona against a container of the pinned build and checks the exact capabilities and scopes it receives.

## References

- ADR 0006 (Part 2 posture), ADR 0007 (organization and tenancy), ADRs 0008 and 0009 (PR #594).
- Issues: #578, #600, #613, #495, #526, #531, #553, #585, #607.
- rpms-rpc: `Authentication.held_keys` (CIAVCXUS HASKEYS), ADR 0010 (the consumer contract: the gem reports facts, the host owns policy).
- Kernel: `$$ACCESS^XQCHK` (option access), `HASOPTN^ORWU` (its RPC).
- SMART App Launch v2 scopes; RFC 9068 (JWT access tokens).
