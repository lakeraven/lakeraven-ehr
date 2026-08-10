# Field street-medicine sync — client/server contract (first pass)

Server-side foundation for running lakeraven-ehr on cellular-data iPads in
mobile vans for street-medicine field encounters (**#418**). This document is
the contract between the field client and the engine, and the record of what
this first pass builds versus defers.

## Why this shape

Two tribal street-medicine programs independently lost most reactive screens
between the field and confirmation/treatment:

- **Cherokee Nation HELP** — HCV 102 reactive → 36 confirmed (35%) → 12 treated;
  syphilis 60 reactive → 18 confirmed (30%) → 16 treated. Top recommendation:
  *onsite confirmation test and treatment*.
- **Sih Hasin (Northern Navajo, Shiprock)** — documents on paper in the field,
  round-trips to the hospital to enter into RPMS.

The server foundation therefore centers on two things: (1) a **conflict-aware,
server-authoritative sync** so an offline van iPad can capture and reconcile
without a live connection, and (2) a **single record that follows the
screening → confirmation → treatment arc** so the drop-off is a queryable
follow-up item instead of a lost paper entry.

## What this first pass builds

| Area | Artifact |
| --- | --- |
| Sync reconciliation | `FieldSyncService` + `FieldSyncOperation` (idempotency ledger + reconciliation queue) |
| Clinical arc | `FieldLabTrackingService` + `FieldLabTrackingRecord` (screen → order → result → treat) |
| Client surface | `POST /field/sync`, `GET /field/work_queue` (`FieldSyncController`) |
| Tests | model, service, and controller/integration specs |

## Sync contract

The field client captures operations offline, each with a **client-generated
idempotency key** (`client_op_id`) and, for updates, the **version it derived
from** (`base_version`, **required** for `update` — an update without it is
rejected, never blindly applied). On reconnect it POSTs a batch to
`POST /field/sync`.

**Identity is token-derived.** The clinician (`clinician_duz`) and site
(`site_ien`) stamped on clinical rows and the ledger come from the bearer token,
not the request body — a device cannot attribute a write to an arbitrary
clinician or site. A token is scoped to its site(s) via the Lakeraven field
extension scope `site/<ien>`; a `system/*.*`/`system/*.write` backend token may
act across sites but must still name the site it queries. Any `clinician_duz` /
`site_ien` in the payload is ignored (for a `system/` token with no bound
resource owner, a payload `clinician_duz` is the documented attribution fallback).

### Request

```jsonc
POST /lakeraven-ehr/field/sync          // Authorization: Bearer <token>, user/ or system/ write scope
{
  "batch_id": "van3-2026-08-09T14:02Z",
  "device_id": "ipad-van3",
  "operations": [
    {
      "client_op_id": "uuid-1",          // idempotency key — REQUIRED
      "operation_type": "create",        // create | update
      "target_type": "FieldLabTracking",
      "payload": { "patient_ref": "panel-42", "condition": "HCV",
                   "screening_test": "HCV Ab rapid", "screening_result": "reactive" },
      "client_recorded_at": "2026-08-09T13:10:00Z"
    },
    {
      "client_op_id": "uuid-2",
      "operation_type": "update",
      "target_type": "FieldLabTracking",
      "target_id": "1837",
      "base_version": 1,                  // version the client last held
      "payload": { "action": "order_confirmation", "confirmation_loinc": "13955-0",
                   "confirmation_order_ref": "ORD-9" } }
  ]
}
```

`FieldLabTracking` update actions: `order_confirmation`,
`record_confirmation_result` (`confirmation_result_status`:
`positive|negative|indeterminate`), `start_treatment`, `mark_lost_to_followup`.

### Per-operation outcomes (server-authoritative)

| Outcome | Meaning | Client action |
| --- | --- | --- |
| `applied` | Accepted; server record is authoritative. | Adopt `server_resource_id` + `server_version`. |
| `conflict` | Update `base_version` ≠ current `server_version`. Server keeps its version; op parked unresolved in the reconciliation queue. **Never overwritten.** | Re-fetch server state; a clinician resolves. |
| `rejected` | Malformed, missing `base_version`, missing required clinical fields, unauthorized site, target not found, or illegal clinical transition. | Fix and resubmit under a **new** `client_op_id`. |
| `unsupported` | No handler for `target_type`. Recorded, not applied — no silent fallback. | Client feature not yet server-backed (see deferred). |

A **replayed** `client_op_id` returns its **original persisted outcome**
unchanged, plus `"duplicate": true`. The replay flag never masks the real
outcome: replaying an op that was `conflict` or `rejected` still reports
`conflict`/`rejected` (with `duplicate: true`), so an unresolved op is never
mistaken for a successful no-op. Replays are safe under concurrency — two
in-flight requests with the same `client_op_id` never double-apply and never
500; the loser is reported as a duplicate replay.

### Response

```jsonc
{
  "batch_id": "van3-2026-08-09T14:02Z",
  "summary": { "applied": 1, "conflict": 1 },
  "operations": [
    { "client_op_id": "uuid-1", "outcome": "applied", "server_resource_id": "1837", "server_version": 1 },
    { "client_op_id": "uuid-2", "outcome": "conflict", "server_version": 2,
      "reason": "base_version 1 != server_version 2" }
  ]
}
```

### Work queue — `GET /field/work_queue?site_ien=463`

Scoped to the token's authorized site(s). A request must resolve to a site: a
`site_ien` the token authorizes, or (for a token scoped to explicit `site/<ien>`
sites) those sites. **Omitting `site_ien` never dumps all sites** — a wildcard
backend token that names no site is refused (`403`), as is a request for a site
the token is not authorized for.

Returns the two things a van clinician needs to close the loop:

```jsonc
{
  "conflicts": [ { "client_op_id": "uuid-2", "target_type": "FieldLabTracking",
                   "target_id": "1837", "server_version": 2, "base_version": 1 } ],
  "follow_ups": [ { "id": 1837, "patient_ref": "panel-42", "condition": "HCV",
                    "stage": "confirmation_ordered", "awaiting": "confirmation" } ]
}
```

`follow_ups` is the direct attack on the confirmation/treatment drop-off:
reactive screens with no confirmation result (`awaiting: "confirmation"`),
confirmed-positive records not yet treated (`awaiting: "treatment"`), and
**indeterminate** confirmation results (`awaiting: "reconfirmation"`). An
indeterminate result is clinically unresolved, so it stays on the queue for a
repeat draw — it is **not** finalized as a terminal `negative`, which would
silently drop the patient. A create with no `screening_result` is rejected for
the same reason: it would sit unqueryable forever.

## Guarantees and non-guarantees

- **Idempotent, even under concurrency.** The ledger row is claimed (unique
  `client_op_id`, in a transaction) *before* the clinical write, so a replay —
  including two simultaneous retries on flaky cellular — never double-applies and
  never 500s; the loser is reported as a duplicate replay.
- **Server-authoritative.** `base_version` is required on updates and the
  compare-and-apply runs under a row lock, so a stale or racing update never
  overwrites newer server state; it becomes a conflict for human reconciliation.
- **No silent failures.** Unknown target types, unknown actions, illegal clinical
  transitions, missing required fields, and unauthorized sites are recorded with
  a reason, never faked as applied.
- **Durable, not yet written back to RPMS.** Synced records persist in the
  engine database. RPC write-back to RPMS is out of scope here (see deferred).
  Write-back is honestly deferred, not faked — there are deliberately no
  `write_back_*` columns yet (unlike `reconciliation_items`); they land with the
  RPC write path.

## Deferred (tracked follow-ups, not built here)

Kept out of the first pass deliberately; each needs its own issue/PR:

1. **Device-side offline store + sync client.** Local encrypted store, batching,
   retry, and the pairing flow live on the iPad. Extends **#410**; token/pairing
   model from **#399/#400**.
2. **Device PHI posture.** PHI-at-rest encryption, remote wipe, session expiry,
   TLS trusted connection — align with **#358** (§170.315(d)(1)) and **#359**
   (§170.315(d)(9)). The write scope check here is the server hook, not the full
   device posture.
3. **Transient-panel identity / MPI.** `patient_ref` accepts a transient panel id
   today; match-before-mint to a durable chart across weeks/sites is **#394**.
4. **RPC write-back to RPMS.** Materialize synced field records (lab orders,
   results, encounters) into RPMS via the RPC layer. RPC specifics stay in
   `rpms-rpc`, not in this engine.
5. **Point-of-care result ingestion.** A typed intake for rapid HCV/HIV/syphilis
   device/analyzer output feeding the screening capture.
6. **MAT / field e-prescribing.** Reuse the existing `EprescribingService`
   (§170.315(b)(3)) from the field surface; wiring and offline queueing deferred.
7. **Additional sync handlers.** Only `FieldLabTracking` is registered. Field
   encounters, vitals, and consent capture need handlers implementing the same
   `create/find/version_of/apply` protocol; until then those op types return
   `unsupported`.
8. **Retention/follow-up automation + cross-org coordination.** corvid#410
   (retention triggers) and corvid#411 (multi-partner coalitions) consume the
   work queue this exposes.
