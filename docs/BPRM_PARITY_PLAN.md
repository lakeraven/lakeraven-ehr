# BPRM ⇄ lakeraven-ehr reg/sched parity plan

**Goal:** guarantee that lakeraven-ehr's registration/scheduling/ADT (over RPMS **RPCs**,
runnable on **YottaDB**, license-free) produces results **equivalent to BPRM v4** (a Blazor
web client whose data path is raw **IRIS SQL** against `BMW`/`BMW_BSF_VW`) — so lakeraven-ehr
is a proven stand-in for BPRM v4's reg/sched, on either engine. Tracks lakeraven-ehr#416.

## What the two systems actually are

Established from the artifacts, not assumption (`rpms-ops/manifests/clients/bprm-4.00.06.yml`,
scanned from 1,040 `.cs` sources; `bprm0400.06.xml`, the IRIS class layer):

| | lakeraven-ehr | BPRM v4 |
|---|---|---|
| Kind | Rails web app | **Blazor _Server_ web app** |
| HTTP surface | HTTP/JSON **API** | Blazor UI over HTTP+SignalR — **no API/REST/RPC tier** (`transport.rpc: none`, 0 `%CSP.REST`/`WebMethod`) |
| Data path | RPMS **RPCs** (`AG`/`BHDPTRPC`, `BSDX`, `DGPMV*`) via `rpms_rpc` | **ADO.NET SQL** (`InterSystems.Data.IRISClient`) → `BMW.BSF.SP.*` SqlProcs (174) |
| Engine | YottaDB **or** IRIS | IRIS only (SQL/BMW class layer) |

Both terminate in the **same FileMan files** — that shared layer is the parity oracle:

```
lakeraven-ehr:  browser/HTTP ─▶ web UI ──▶ RPCs             ─┐
                                                            ├─▶ FileMan  (#2, #9000001, #44, #409.*, #405)
BPRM v4:        browser/HTTP ─▶ Blazor UI ─▶ SQL(IRISClient) ─┘        └── read-back = shared truth
```

## Two parity axes

| Axis | Compared | Identical because | Where "identical" needs care |
|---|---|---|---|
| **Engine** | lakeraven-ehr on **YDB** vs **IRIS** | same RPCs, same M routines, same FileMan | normalize IEN/DFN/DUZ/timestamps |
| **Path/app** | lakeraven-ehr **RPC** writes vs BPRM **BMW-SQL** writes | different code, same target files | BPRM has no HTTP API — drive its UI (Tier 2) or its SqlProcs directly (golden) |

"Identical on both" means **outcome-identical FileMan state**, not pixel-identical UI or
byte-identical HTTP bodies (the two apps' JSON differs by design).

## Test strategy — two tiers (test pyramid)

### Tier 1 — fast, every commit
1. **Engine parity.** Run the lakeraven-ehr HTTP request suite against **both** an rpms_rpc
   **YDB** backend and an **IRIS** backend; assert **byte-identical responses** after
   normalization. This is the cheap, strong check — same code on two engines *must* agree.
2. **Path parity.** After each write scenario, capture lakeraven-ehr's **FileMan read-back**
   (`$$GET1^DIQ` per field / `$$GET^DIQ` over a field list) and assert it equals a **BPRM golden** —
   the FileMan state produced by invoking the same `BMW.BSF.SP.*` SqlProcs directly (SQL, not
   HTTP) with the same inputs. Goldens are captured once per scenario and committed; the
   capture script is checked in so they regenerate deterministically.

### Tier 2 — faithful, periodic (needs the BPRM Blazor stack up)
- **Playwright** drives **both web apps'** UIs through the same clinical workflows; assert
  identical FileMan read-back. This exercises BPRM the way a clinical user actually uses it (its
  only HTTP surface is the UI), and is the true app-to-app parity check. Runs on a schedule / on
  demand, not every commit, because it needs a live BPRM + IRIS deployment.

## The oracle: FileMan read-back + normalization

- **Compare the persisted record**, keyed by patient/appointment/movement, via FileMan reads —
  never the HTTP envelope.
- **Normalize before diff:** assigned IENs and DFN, DUZ of the entering user, entry/edit
  date-times (`.01`-style audit stamps), appointment internal IDs, `^DGPM` movement IENs.
  A field is normalized only if it is *provably* non-semantic (an identity/timestamp), never
  to paper over a real divergence.
- **Error parity is part of parity:** the same invalid input must be **rejected the same way**
  on both paths. BPRM raw-writes bypass some FileMan cross-references (see the
  `adt_movement.feature` disposition `sql-mutate -> reimpl`); lakeraven-ehr writes through
  `DGPMV*`/`^DIE`, so parity is asserted at the **validated FileMan layer** — where BPRM's
  bypass is a defect to flag, not a target to match.

## Harness shape

```
features/bprm_twin/*.feature        # domain scenarios (exist) + parity.feature (new)
features/support/
  backends.rb                       # BACKEND=ydb|iris → rpms_rpc connection
  bprm_golden.rb                    # invoke BMW.BSF.SP procs on IRIS, capture FileMan read-back
  fileman_readback.rb               # $$GET1^DIQ helpers over the parity field set
  normalize.rb                      # strip/canonicalize non-deterministic fields
test/fixtures/bprm_golden/*.json    # committed BPRM-SQL goldens (regenerable)
```

Tier 1 runs under `cucumber` in CI against both backends; Tier 2 is a separate Playwright
job gated on a `BPRM_E2E=1` env with a reachable BPRM base URL.

## Sequencing / blockers

- **Blocked on RPMS Kernel sign-on on YDB (rpms-ops#343)** for the live YDB backend arm — RPC
  round-trips can't sign on until that gate is cleared (same `Logins prohibited` gate seen on
  keyless IRIS). **Not** blocked for building Tier-1 engine-parity against IRIS or the
  BPRM-SQL golden capture — those can land first.
- The domain scenarios (`clinic_schedule`, `adt_movement`, `waiting_list`, …) already exist as
  stubbed executable specs; this plan adds the **parity assertions and real backends** behind
  them, it does not replace them.
