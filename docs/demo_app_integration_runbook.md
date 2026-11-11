# Referral-loop demo runbook (prototype)

Branch `demo/app-integration`, not for merge. It shows the loop epic #993 describes: an approved
outside outreach app reads an open referral over FHIR, posts what it learned from calling the patient,
a coordinator confirms it, and the confirmed result lands back on the RPMS referral. The real build
is the factory slices on #993; this branch only demonstrates the shape.

**Synthetic data only.** The patient (Anderson, Alice, DFN 1, from `test/dummy/lib/lakeraven_demo_seeds.rb`),
the referral `DEMO-2026-0042`, the outside facility, the coordinator and the app are all invented.
RPMS is the in-memory mock broker (`RpmsRpc.mock!`). Nothing connects to a live RPMS, Corvid or any
third-party service.

## Run it

Needs Ruby (`.ruby-version`), `bundle install`, and the dev Postgres the chart demo uses
(`docs/demo_patient_chart_runbook.md`).

```sh
test/dummy/bin/demo-app-integration                # the whole loop, about 5 seconds
DEMO_PAUSE=1 test/dummy/bin/demo-app-integration   # press Enter between steps, for presenting
```

It exits 0 and ends with a summary table when every step ran. A step that fails prints `FAILED` with
the HTTP answer it got and exits 1.

## What is real and what is mock

| Step | What the audience sees | Status | Real build |
|---|---|---|---|
| 1 | A site admin registers the outreach app (Doorkeeper app bound to the organization, with its JWKS URL) | REAL; the JWKS URL is answered in-process because the demo has no public host | |
| 2 | The app gets a SMART Backend Services token (`client_credentials`, signed RS384 JWT) | REAL: the engine's own token endpoint | |
| 3 | The app reads `Patient/1` and `ServiceRequest?patient=1` | REAL engine FHIR controllers, reading the mock broker. Against a live broker this answers 503 today | #996 |
| 4 | The app posts the call outcome as a FHIR `Communication` | MOCK. The demo really posts it and shows the engine's 404, then holds it in a stand-in store | #988 |
| 5 | A coordinator sees it in a queue, labeled AI-generated, and confirms it | MOCK (console only, no screen) | #989, #1000 |
| 6 | The confirmed result writes the appointment date and a scheduling note to the RPMS referral | MOCK: the mock broker's referral row is re-seeded | #990, #997, rpms-rpc#722 |
| 7 | Corvid records the follow-up | NOT BUILT: the payload it would send is printed | #998 (Corvid frozen until after the pilot) |
| 8 | Read-back: the referral as RPMS now holds it | REAL reads (engine FHIR, then `BMC SEARCH REFERRAL` through rpms-rpc) of the row step 6 mock-wrote. The FHIR mapping does not carry the appointment date yet | |

## Talking points that stay true

- A person confirms every result before it reaches RPMS or Corvid (#993 guardrails).
- No AI-generated note is filed to RPMS unsigned; the signed-note path (#999) is not shown.
- No PHI goes to an outside app without an executed BAA (#368, #991). This demo uses none.
- The FHIR API stays closed in the December pilot build (#970); this loop is post-pilot.

## Files

- `test/dummy/lib/tasks/demo_app_integration.rake`: the walkthrough (`bin/rails demo:app_integration`)
- `test/dummy/lib/demo/outreach_app.rb`: the stand-in outside app (plain SMART Backend Services and FHIR over HTTP)
- `test/dummy/lib/demo/referral_loop_mock.rb`: the mock of steps 4 to 7
- `test/dummy/bin/demo-app-integration`: the one command
