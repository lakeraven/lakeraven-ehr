# Outside app integration demo: runbook

This is a demo prototype on synthetic data, for #992 and #993.

- It is not in the December build.
- The FHIR API is not certified.
- This branch, `demo/app-integration-writeback`, is never merged.

It shows what any registered outside app needs, whether that is an outreach app or a scribe:

1. Read a referral.
2. Post a result.
3. Have a person confirm the result before it reaches RPMS.

## Run it

The test harness needs no RPMS. Its RPMS replies are seeded:

```sh
bin/demo_app_integration
```

To run against live RPMS, use a machine where `docker login ghcr.io` works. Both repos must be checked out side by side.

```sh
cd rpms-rpc && git switch demo/app-integration-gem
LAKERAVEN_EHR_PATH=../lakeraven-ehr bin/cloud_rpms up    # broker on 127.0.0.1:9100
cd ../lakeraven-ehr && git switch demo/app-integration-writeback && bundle install
RAILS_ENV=test bin/rails db:create db:schema:load
bin/demo_app_integration --live
```

The live run writes to a synthetic referral of the synthetic patient DFN 990003. If that patient has no ACTIVE referral, the run files one with DDR FILER. Each run adds one case note.

**Success:**
- The run ends with `DEMO COMPLETE: live RPMS` and `[demo] passed (live)`.
- Step 5 prints the referral's 1106 starting `3261204`.
- Step 5 prints the newest case note: `Outside app Registered outside app (stand-in) (AI-generated, confirmed by ...): Patient says the cardiology appointment is booked for 12/4. Appointment 12/04/2026.`

## Proven live, and still mock

| Step | Test harness | Live |
|---|---|---|
| 0. Register the app, get a SMART Backend Services token. A token without `Communication.c` is refused the write. | passes | not yet run live (no RPMS call in this step) |
| 1. GET Patient and ServiceRequest over FHIR | passes | not yet run live. The live run signs the whole process on as the demo user. A deployed stack answers a backend token 503 until #844. |
| 2. The stand-in client posts a Communication | passes | not yet run live |
| 3. Held as pending (`in-progress`), audited, nothing sent to RPMS | passes | not yet run live |
| 4. The coordinator confirms on `/referrals/follow_ups` | passes | not yet run live |
| 5. BMC UPDATE REFERRAL files the date and a case note, then DDR reads them back | passes, with every RPMS reply seeded | not yet run live. rpms-rpc#722 and its live spec `test/live/referral_follow_up_live_test.rb` |

## Not done here

- Corvid (#990).
- Patient opt-out and the BAA gate (#991).
- The outbox and reconciliation (#262).
- The CapabilityStatement entry for Communication, which waits on #970.
- A signed TIU note path.
