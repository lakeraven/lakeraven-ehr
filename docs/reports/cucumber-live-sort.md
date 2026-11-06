# Cucumber: what reaches RPMS (2026-11-05)

The whole suite ran once on the mock and once live, against a fresh container of the published `bcer-9.0-20261104-9b5cccd-ydb` image.
Every scenario, with its category and the RPCs it made, is in [`cucumber-live-sort.tsv`](cucumber-live-sort.tsv).

| Category | Scenarios | What it means |
|---|---|---|
| a. App | 609 | Logic inside the app. It reached no RPMS and stubbed no RPMS read. |
| b. Live | 107 | Reached RPMS and passed. 20 of these also stub part of the path; the tsv names what. |
| c. Fails live, a real defect | 0 | |
| d. Fails live, environment only | 0 | 17 failed on the first run; all were test harness, and are fixed. |
| e. RPMS-dependent, stub only | 29 | The RPMS read is stubbed, so a pass shows what the app does with an input we wrote. |
| f. Undefined, pending, skipped or unsourced | 77 | Specifications and parked acceptance tests. |

Total: 822.

## How to read this

- A live pass means more than a mock pass only for category b.
- The live run exercised 19 distinct RPCs, and all of them are reads or sign-on.
  No scenario writes to RPMS.
- Zero real defects means the scenarios we have agree with RPMS.
  It does not mean the engine is proven against RPMS.
- 13% of the suite reaches RPMS, so a green mock run says very little about RPMS.

## How to run it

```sh
bundle exec cucumber --profile app
LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=<port> \
LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
bundle exec cucumber --profile live --tags @live
```

Dropping `--tags @live` runs everything against the broker, which is how to re-sort the suite.
