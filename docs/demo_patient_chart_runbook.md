# Patient Chart Demo Runbook — lakeraven-ehr

Read-only demo patient chart (issue #452, PR #453). Synthetic data only — no PHI.

## Start (local, synthetic data only)

Preferred — runs the preflight checks automatically:

    /Users/kimball/code/lakeraven/rpms/lakeraven-ehr/test/dummy/bin/demo

Equivalent manual start:

    cd test/dummy
    CHART_DEMO_OPEN=1 SPIKE_MOCK_RPC=1 bin/rails server

- `SPIKE_MOCK_RPC=1` — mocks only the RPMS wire; all engine gateways/models run for real.
- `CHART_DEMO_OPEN=1` — dev-only auth bypass (impossible in test/prod; SMART auth otherwise required).

**URL:** http://localhost:3000/chart/1

## Preflight (5 minutes before)

`bin/demo` does all of this for you; if starting manually:

1. **Port 3000 free?** A previous dummy server (or its stale pidfile) is the most
   likely failure. `lsof -ti:3000 | xargs kill; rm -f test/dummy/tmp/pids/server.pid`
   — or just reuse the already-running server if it is serving `/chart/1` correctly.
2. **Postgres up?** `pg_isready || brew services start postgresql`. Dev-mode
   migration checking queries the DB on every request; a down Postgres 500s everything.
3. **Clean env.** `unset RPMS_RPC_PATH` (flips the Gemfile to a path source →
   bundler rejects the lockfile) and make sure no stray `RAILS_ENV` is exported —
   both demo flags are honored **only in development**.
4. **Remote screen?** Puma binds localhost. Showing from another device on the
   network needs `bin/demo -b 0.0.0.0`. A local browser needs nothing.
5. **Smoke test:** open http://localhost:3000/chart/1 (expect Alice Anderson) and
   http://localhost:3000/chart/1.json (expect a FHIR Bundle).

## Walkthrough (5 steps)

1. **Open http://localhost:3000/chart/1** — a clinician-readable chart for Anderson, Alice
   (DFN 1, synthetic). "This is a live render, not a screenshot or a static page."
2. **Scroll the sections** — demographics, problems, allergies, vitals, medications,
   procedures, appointments, immunizations. "Every section came through the engine's
   real gateways; only the RPMS source is mocked today."
3. **Add `.json` to the URL** → http://localhost:3000/chart/1.json — a FHIR R4 Bundle.
   **The line:** "One URL is a human chart; append `.json` and it's FHIR-native —
   same engine, same data, two representations."
4. **Match a data point** — pick a problem or vital in the JSON and show the identical
   value in the HTML tab. "There's no sync job and no export step. It cannot drift."
5. **Close on standards** — same Bundle also serves `Accept: application/fhir+json`
   and `?_format=json`, so EHR-integrators and browsers hit the exact same endpoint.

## Likely questions

- **"Is this real patient data?"** No — fully synthetic ("Anderson, Alice"), invented
  for the demo. Real deployments read live RPMS through the same gateway interface.
- **"Is it secured?"** Yes, and it fails closed: SMART-on-FHIR bearer tokens, per-resource
  read scopes (unreadable sections are omitted), patient-context binding, and audit on
  every access. Today's open view is a dev-only flag that cannot ship to production.
- **"Can we write data / is it read-only?"** This chart is read-only by design. Writes
  go through the RPC layer with RPMS as the system of record — reads via FHIR, writes
  via RPC — so RPMS stays authoritative and nothing here forks the data.

## Key files

- `app/controllers/lakeraven/ehr/charts_controller.rb` — auth/bypass semantics, Bundle assembly
- `test/dummy/config/initializers/zz_spike_mock_rpc.rb` — SPIKE mock wiring (documents the start command)
- `test/dummy/lib/lakeraven_demo_seeds.rb` — the synthetic "Anderson, Alice" seed set
- `test/dummy/bin/demo` — preflight + boot script
- `test/integration/demo_patient_chart_test.rb` — locks the demo behavior (both representations + auth)
