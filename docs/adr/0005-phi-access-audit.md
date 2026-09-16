# ADR 0005: PHI access audit — fail closed, tamper-evident, reviewable

**Status:** Proposed
**Date:** 2026-09-14
**Issue:** #488 (hard gate for the December pilot)

> **Implementation status.** This ADR describes the whole audit posture; after the round-1
> adversarial gate on #507 it lands as four independent PRs, each safe alone off `main`:
> the fail-closed core + attribution (this document's §1–§3, carrying this ADR),
> tamper-evidence + retention (§4–§5), the review surface (§6), and the demo charting
> surface. A section below whose mechanism has not merged yet is design, not description —
> check the sibling PRs referenced from #488 for what is actually on `main`.

## Context

No real patient data enters this system until PHI access audit logging is production-grade.
The posture before this decision had a working `AuditEvent` model and an `after_action` that
wrote a row on success, which lost the two kinds of event most worth keeping:

- Rails skips after-callbacks when a before-callback halts the filter chain, so **every 401
  and 403 was invisible**. A clinician probing charts outside their compartment left no
  trace — which is §164.312(b)'s question, exactly. Tightening authorization without fixing
  this makes the log quieter, not safer.
- A failed insert was logged and **the response — the PHI — went out anyway**.

Two further defects were found in the first corrected version of the pattern and are the
reason several of the decisions below are stated so specifically: recording after `yield`
outside a transaction left committed writes with no audit row, and a refusal that discarded
its response body still carried the patient name out in the **flash**, in the session cookie.

## Decision

### 1. The audit wraps the action, and fails closed

`AuditableClinicalAccess` registers an `around_action` at include time, before each
controller declares its own `before_action`s — so it wraps a halted chain and records the
refusal. The audit row is written inside `ActiveRecord::Base.transaction(requires_new: true)`
together with whatever the action wrote.

`requires_new: true` is load-bearing. A plain nested `transaction` **joins** its parent, and
a join is not a rollback boundary: an exception escaping it leaves the parent's writes in
place. Rails opens the transactional-test wrapper with `joinable: false`, which silently
promotes any inner transaction to a savepoint — so the rollback "works" in every test while
failing for a service or importer that owns its own transaction. The test for this owns a
joinable transaction deliberately.

When the access cannot be recorded, it is not completed: 503, the response body discarded,
**headers cleared by difference against the set that existed before the action ran**, and the
flash cleared and swept. Discarding the body is not discarding the response.

"Recorded" and "needed no record" are both settled outcomes; only "should have been recorded
and could not be" refuses. That distinction exists because the concern is mixed into whole
controller bases, and a browser base serves pages that touch no patient data and name no user.

### 2. Attribution names a human where one exists, and says so when one does not

**Attribution is keyed on the MECHANISM that authenticated (or refused) the request — never
on a precedence chain over whatever identities happen to be present.** An earlier draft of
this section ordered `current_duz` → `session[:duz]` → token; following that chain
reintroduces the central misattribution defect, because a session (and a session-derived
`current_duz`) can be *present* on a request it did not authenticate — a bearer-token API
call from a signed-in browser, a tokenless cross-site GET riding a SameSite=Lax cookie.

The shipped rule, per mechanism:

- **Bearer token present** → the token's human, and only via `browser_sso_token?` (#486)
  proving the token is the session-bound browser token. Any other token records its
  **application uid** (unless it is the shared browser application, which records
  `Unknown`), and a co-present session or `current_duz` is written to the row as an
  **identity anomaly** — recorded, never silently resolved, never the actor.
- **No token, on a surface that declares `session_authenticated_surface?`** (the browser
  base, whose `require_authentication` gates on the session) → `current_duz` /
  `session[:duz]`.
- **No token, on a token-authenticated surface** → nobody: the refusal records
  `Unknown`, with any bystanding session noted as an anomaly.
- **A bypass surface** (`unauthenticated_audit_actor`) was authenticated by its own gate
  and never consults the session at all.

**`current_duz` and `session[:duz]` never outrank a bearer token by mere presence.**

**An unattributed row is worth more than a misattributed one.** Filing a browser access under
the shared OAuth application uid makes every clinician in the building look like the same
actor, which is precisely the question "who opened this chart" is asked to answer.

### 3. Coverage

| Surface | How |
| --- | --- |
| FHIR API (all resource controllers) | `ApplicationController` includes the concern |
| Patient chart (HTML + FHIR) | `ChartsController` includes it; the dev demo bypass declares a service actor |
| Every browser page | `WebController` includes it, so pages added later are covered on the day they are written |
| Demo charting surface | included, though dev-only and synthetic |
| Compliance review screen | audited like anything else, filed under the human who read it |
| RPMS backend actions | `RpcSupport.broker` returns an `AuditedBroker` |
| Break-glass | `EmergencyAccess` writes its own row in the same transaction as the grant |

`AuditedBroker` records the RPC name, actor, network address, tenant and facility, and
whether the call completed — **never the parameters**, which is where the PHI is. It fails
closed: an RPC whose audit cannot be written does not return its result.

**A stated asymmetry of that guarantee (honesty ledger):** the RPC executes *before* its row
is written, so for a **mutating** RPC whose audit insert then fails, the remote change has
already committed — withholding the Ruby result cannot undo RPMS. Fail-closed is therefore
complete for reads (the data never reaches the caller) and **best-effort for writes** (the
caller is refused, but the backend effect stands unrecorded except in server logs). Closing
it needs a pre-execution reservation — and because audit rows are immutable, that means a
two-row dispatch/result protocol per RPC (doubling log volume and changing what the review
surface counts) or a mutating-RPC classification list, which this broker deliberately
refuses to maintain (a wrong entry is a row that lies). That is a design decision for the
log's consumers, not a patch — filed as a follow-up issue alongside #505/#506.

**Not covered:** gateways that call the `RpmsRpc::*` API modules directly reach the configured
client without passing through `RpcSupport.broker`. In a request those are covered at the HTTP
boundary; outside one they are not covered at all. Closing that needs a client-level hook in
`rpms-rpc` rather than more wrappers in the engine.

### 4. Tamper-evidence: keyed digest + database append-only, no hash chain

Each row is sealed at insert with a digest of what it says — HMAC-SHA256 when
`audit_digest_key` is configured, plain SHA-256 otherwise. The key lives outside the database
so someone who can write the rows cannot re-seal them. `integrity_mode` states which is in
force; a reviewer who assumes the keyed answer on an unkeyed log is being misled by omission.
A row carrying **no** digest is reported, not forgiven.

On PostgreSQL a trigger refuses `UPDATE` on the table. **Its limits, stated plainly rather
than rounded up:** the application role owns the table, and a table owner can
`ALTER TABLE … DISABLE TRIGGER`, `TRUNCATE`, or `DELETE` — the trigger constrains
applications and mistakes, not an owner. It prevents neither `DELETE` nor `TRUNCATE`
(deletion is *permitted by design* — the retention purge needs it — detected only by the
purge-receipt trail, with cryptographic ordering deferred to the periodic-seal follow-up,
#506). An integrity screen must therefore report whether the trigger is *actually installed
and enabled* (a capability probe is not an installation fact — see the tamper-evidence PR of
this split), and this ADR must not be read as claiming database-enforced immutability
against a table owner. The trigger cannot live in `schema.rb`, so it is a model call
(`AuditEvent.enforce_append_only!`) that the migration makes and a schema-loading host can
make itself.

The digested field list is **explicit and frozen**. Deriving it from `column_names` would mean
any later migration adding a column silently invalidated every digest already written, and the
whole log would read as tampered.

**We did not implement a hash chain.** Chaining each row to its predecessor needs a
serialization point at insert, and the only honest one is a lock held for the whole enclosing
transaction — which would put every PHI access in the system behind a single audit writer.
That leaves deletion and reordering — the things a chain is for — **detectable only through
the purge-receipt trail, not prevented** (see the trigger's limits above). If the pilot's
risk assessment wants cryptographic ordering, the cheaper shape is a **periodic seal**
(a signed digest over a time range, written by a job) rather than a per-row chain; that is
filed as #506.

### 5. Retention

Six years (§164.316(b)(2)(i)), and six years is a **floor**. A host may configure longer; a
shorter setting is refused rather than honoured, because a purge reaching inside the retention
window destroys records the rule still requires and does it quietly. `AuditRetention.purge!`
leaves its own audit row — a deletion nobody can see is worse than keeping the records too
long. Driven by `rake lakeraven_ehr:audit:purge`.

### 6. Review without engineering

`/audit-review` filters by who, which record, which kind of record, action, outcome, tenant
and date range, with CSV for reports and an integrity screen. Gated on a site-configured
reviewer security key; **an empty configuration refuses everyone**, because the RPMS key that
means "may read the audit log" differs per site and inventing a default here would open the
log to whatever that name happens to mean at a real deployment.

A date filter that will not parse is reported rather than dropped, and the empty state says
plainly that no matching records is not evidence that no access happened.

## Consequences

- Every PHI surface either produces an audit row or does not complete. Outages in the audit
  store become outages in the application — deliberately.
- Audit rows are immutable at the database on PostgreSQL. Operational tooling that expected to
  fix up rows must instead write a correcting row.
- The engine's own database now has to be available for an RPMS backend call to complete,
  because the backend call is audited.
- Sites must configure `audit_review_security_keys` before anyone can review the log, and
  should configure `audit_digest_key` before the log is worth anything against forgery.
