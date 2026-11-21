# ADR 0018: Terminology sits behind one adapter, with RPMS as the first source

**Status:** Proposed
**Date:** 2026-11-21
**Decides:** how the engine looks up codes, expands value sets and translates RPMS local codes to standard ones; which servers sit behind that seam; and what happens when a lookup fails

## Context

Coded data leaves this engine on every FHIR read, every CQM/GPRA calculation and every C-CDA. Today the coding comes from three places that do not talk to each other:

- **Codes on the RPMS record.**
  - Problems and visit diagnoses carry ICD-10-CM and a SNOMED CT concept (`Problem`, `Pov` in rpms-rpc).
  - Lab results carry a LOINC code when the site mapped the test.
  - Health factors, measurement types and exams carry IHS-local codes with no standard code.
- **BSTS inside RPMS.** RPMS's terminology package (IHS Standard Terminology 2.0, context `BSTSRPC`) serves SNOMED search, concept detail and code sets. It answers on our 9.0 builds (`BSTS SEARCH TYPE AHEAD` in the rpms-rpc conformance inventory). rpms-rpc has no symbolic API for it yet.
- **`TerminologyService` in this engine.**
  - It detects three backends (local JSON, VSAC, IRIS) but implements only local JSON.
  - The engine ships no value sets, so the local backend serves only what a host app contributes.
  - If `UMLS_API_KEY` or `IRIS_TERMINOLOGY_URL` is set, it selects a backend whose expansion raises "Unknown backend".
  - `ValueSetsController#index` and `#show` rescue `NotImplementedError` into an empty Bundle and a 404. A broken terminology backend therefore looks like "no value sets", which breaks design principle 2 (a failure is never an answer).

Quality measures (GPRA/CRS, eCQM) decide "is this patient in the denominator" by asking whether a code falls in a value set. RPMS answers that with **taxonomies**: named code lists shipped in CRS patches, some of which each site fills in by hand (lab and drug taxonomies). The same lists are needed by:
- this engine (CQMs, US Core coding);
- rook (the CRS/eCQM replacement, which reads RPMS-, Epic- and Greenway-shaped data);
- aviary (the sovereign data lake).

Prior issues already point here:
- #164: adapter pattern;
- #120: FHIR gateway backend;
- #149: SNOMED/LOINC/RxNorm as the canonical layer;
- #265: a governed, versioned value-set and concept-map registry;
- #365: VSAC licensing;
- rpms-rpc#45: a local-code crosswalk, closed not planned.

This ADR gives those issues one decision to hang from.

Design principles that bind:
- **Principle 1:** RPMS is the system of record.
- **Principle 2:** one door to RPMS, and a failure is never an answer.
- **Company principle:** core logic in house; commodity functions behind pluggable adapters.

## Options

### A. Keep `TerminologyService` as is, add backends in its case statements

- For: no new concepts.
- Against: every backend is another branch in one class. Failure handling differs per branch, and nothing else (rook, aviary) can share it.

### B. Adopt one external terminology server as the system of record for terminology (OCL, Snowstorm, Ontoserver or Apelon DTS)

- For: one place for everything.
- Against:
  - It duplicates what BSTS and the RPMS code files already hold, a second copy that drifts.
  - It couples the engine to one vendor's server.
  - Ontoserver is closed-source and commercial outside Australia.
  - Apelon DTS is the pre-FHIR generation that BSTS already wraps.

### C. One adapter interface; RPMS is the first source; an open-source server holds only what RPMS has no place for

- A single `Terminology` port with four operations, `lookup`, `validate_code`, `expand` and `translate`, plus two catalog reads, `read_value_set` and `list_value_sets`. Its shapes follow FHIR `CodeSystem/$lookup`, `ValueSet/$validate-code`, `ValueSet/$expand`, `ConceptMap/$translate`, and ValueSet read and search.
- An **RPMS adapter** answers from the RPMS record and BSTS, through rpms-rpc gateways, never by naming an RPC.
- A **FHIR terminology adapter** answers from any FHIR terminology server. The first deployment is a self-hosted **Open Concept Lab (OCL)**, holding three kinds of content:
  - mappings from RPMS local codes to SNOMED/LOINC (ConceptMaps);
  - CRS taxonomies as ValueSets, published as immutable, tenant-scoped snapshots (see decision 5);
  - eCQM value sets mirrored from VSAC.
- **Snowstorm** is added behind the same adapter when a consumer needs SNOMED hierarchy queries (ECL), which OCL does not do well.
- A **local adapter** (today's JSON files) stays for tests and air-gapped demos.
- A composite tries the sources in a configured order per operation. A source that errors stops the chain with a typed error. Only a source that answers "not found" passes to the next.

## Decision

**Option C.**

1. **One port.** `Lakeraven::EHR::Terminology::Port` defines four operations: `lookup(system, code)`, `validate_code(code, system:, value_set:)`, `expand(value_set, version:)` and `translate(code, system:, target:)`. It also defines two catalog reads, `read_value_set(id, version: nil)` and `list_value_sets(query: nil)`, with the same typed failures. The value-set and FHIR controllers, the CQM engine and the FHIR serializers call the port, never a backend.
2. **RPMS first, read-only.** The RPMS adapter serves SNOMED via BSTS and the RPMS-local code systems (health factors, measurement types, exams) as read-only CodeSystems. Nothing is written to RPMS under this ADR. Writing value sets back into RPMS taxonomies is a separate decision.
3. **An open server holds only what RPMS can't.** That means mappings, versioned value sets and tribe-owned code systems. OCL is the first; Snowstorm is added when ECL is needed. Both are open source and self-hostable, so a tribe can run its own. Terminology content is not PHI, so the server holds no patient data and is outside the BAA boundary.
4. **Failure is typed, never empty.** An unreachable or erroring source raises `Terminology::Unavailable`. What the caller does with it depends on what it is serving:
   - **Terminology endpoints** (`ValueSet`, `CodeSystem`, `ConceptMap` reads and operations) return a 503 `OperationOutcome`. Their whole answer is terminology.
   - **Patient-resource reads** (an Observation search, for example) still return the clinical data with its RPMS local coding. They add an `OperationOutcome` warning naming the codes that could not be translated. Readable clinical data is never withheld because a translation service is down, and the gap is never silent.
   - **Measures** that can't expand a value set report "could not determine" for that measure, never a count of 0.
   - The UI shows a message in every case.

   "Code not in value set" is an answer only when the expansion succeeded.
5. **Versions are pinned and immutable.** A published value set is a snapshot that never changes. Its identity is the value-set id plus a version, `<CRS year>.<revision>`, and site-populated taxonomies (lab and drug lists) are scoped to the tenant. Any membership change, including a site editing its lab taxonomy mid-year, publishes a new revision rather than replacing the old one. Every expansion names its version, and a report run records the tenant, value-set ids and versions it used. Re-running a period therefore gives the same denominator.
6. **Unmapped is shown, never guessed.** A local code with no mapping is emitted with its local coding only. The engine never picks a "closest" standard code.
7. **Hard surface where it decides money or eligibility.** A value set that drives an eligibility, coverage or payment decision (e.g. Corvid's PRC emergency diagnosis list) takes the hard panel. A failed expansion there never confers eligibility.
8. **Code system URIs.** RPMS-local systems use one stable base, `https://fhir.lakeraven.com/CodeSystem/rpms-<file>` (e.g. `rpms-health-factor`), with site-local additions qualified by the tenant. *Open:* confirm the base URI before the first CodeSystem ships.

## Consequences

- #164 becomes the adapter slice of this ADR, without its Swedish scope, which stays parked under #433. #120 becomes the FHIR terminology adapter; #265 becomes the OCL content slices; #365 stays the VSAC licence, which the mirror needs.
- rpms-rpc gains a symbolic BSTS API (search, concept detail, code sets) and read APIs for the local code files.
- The `ValueSetsController` rescue-to-empty goes away; a test pins it.
- Deployments gain one optional service (OCL). Without it, the engine still answers from RPMS and local files; mapping and taxonomy operations return `Unavailable`, never empty.
- rook and aviary consume the same server through their own copy of the port. They gain shared, versioned value sets without depending on this engine.
- **Not decided here:** writing taxonomies back into RPMS; Snowstorm's deployment; licensing IMO or any commercial interface terminology (not planned); country packs (#433).
