# ADR 0003: Data migration ETL suite stays archived in rpms_redux, not ported

**Status:** Proposed
**Date:** 2026-05-24

## Context

The legacy `rpms_redux` monolith included a third-party EHR ETL data-migration suite: 8 services and a corresponding cucumber feature, originally built to migrate patient records from a specific vendor system into RPMS at customer cutover. None of it ported during the engine decomposition.

Existing port issues (#55 data migration should port to host app, #106 data_migration should port from rpms_redux) were filed without a placement or activity decision. The audit (#324) flagged this as one of four strategic decisions blocking execution.

Signals reviewed:

- No active customer migrations are documented in project memory or pipeline records as of audit time
- Recent feature work in `corvid` (Medicare repricing, Section 506 recovery) is greenfield, not migration-driven
- The ETL suite is vendor-specific — its schema mappings target one third-party EHR's data model; reuse for a different vendor would require near-total rewrite
- The migration code is preserved in the `rpms_redux` archive (read-only reference) per the broader archival plan

## Decision

**The ETL suite stays archived in `rpms_redux`. It is not ported to any rig.**

`#55` and `#106` are closed as "won't fix; archived in rpms_redux for forensic reference." If a future customer migration emerges, the right move is to:

1. Read the rpms_redux archive to understand the vendor schema mappings
2. Build a fresh, greenfield migration tool tailored to that customer's source system
3. Place it in a dedicated repo (e.g., `lakeraven-migrate-<customer>`) or in `lakeraven-integrations` — not in the engine

The engine stays free of vendor-specific schema bleed.

## Consequences

### Positive

- The engine doesn't carry vendor-specific ETL logic that nobody is currently using.
- If/when a real migration is needed, the implementer can scope the tool to the actual source system, not retrofit a generic ETL framework that pretends to be vendor-agnostic.
- Two open port tickets close, reducing noise in the audit backlog.

### Negative

- If a customer migration emerges quickly, there's a cold-start cost to rebuild from the archive rather than continue an active codebase.
- Forensic value of the archived code degrades over time as the surrounding engine evolves — the mappings reference rpms_redux's models, not the rigs'.

### Alternatives considered

- **Port the generic ETL core; drop vendor-specific adapters.** Rejected. The "generic core" is mostly orchestration scaffolding (extract → transform → load → reconcile) that's faster to rebuild than to port + retest against new model shapes.
- **Port everything into `lakeraven-integrations`.** Rejected as premature. lakeraven-integrations is an active integration-adapter monorepo; loading it with dead ETL code that nobody is consuming creates maintenance drag.
- **Port into a dedicated `lakeraven-migrate` rig.** Rejected unless customer activity emerges. A new rig for code with no current consumer is overhead.

## Reversal trigger

If a customer cutover commits before the rpms_redux archive becomes unmaintainable, revisit this ADR. The first migration project is in scope for `lakeraven-migrate-<customer>`; only if a second migration appears with substantial mapping overlap does it become worth abstracting a shared library.

## References

- Issue #328 (this ADR closes the strategic-decision portion of)
- Issue #324 (rpms_redux port audit umbrella)
- Issue #55 (host-app data migration port) — closes when this lands
- Issue #106 (rpms_redux data migration port) — closes when this lands
