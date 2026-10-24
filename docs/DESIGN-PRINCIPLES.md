# lakeraven-ehr design principles

**Status:** Proposed, 2026-10-23.
These are the principles a change to this engine is judged against.
ADRs record individual decisions; this page states the rules those decisions follow, so a new decision has something to agree or disagree with.
Each principle lists what it means in practice, where the code stands today, and the next step.

lakeraven-ehr is a Rails 8.1 engine that serves a web EHR and a FHIR API over RPMS.
RPMS stays the system of record; this engine is a front end and an integration surface for it.

## 1. RPMS is the system of record; this engine keeps only what RPMS cannot

**Why.** Two copies of clinical data drift, and the copy outside RPMS is the one nobody's workflows maintain.

**In practice.**
- Clinical data is read from and written to RPMS through rpms-rpc, at request time.
- PostgreSQL holds what RPMS has no place for: the audit log (ADR 0005), sessions and tokens, client registrations, record-level sensitivity labels (ADR 0006), and job state.
- Every table names its owner and why RPMS can't hold it, in its migration or model comment.
- Process-global in-memory stores are for tests and demos only, never a source of answers in production.

**Today.** Mostly true. Some stores are process-global singletons (#589), and a few features keep engine-only state that RPMS should hold (signed CPOE orders, #641).

**Next.** File each engine-held clinical record against #641 or retire it.

## 2. One door to RPMS, and a failure is never an answer

**Why.** An EHR that shows "no allergies" when it couldn't read allergies is worse than one that shows an error.

**In practice.**
- Gateways are the only callers of rpms-rpc, and they call its symbolic API; engine code never names an RPC.
- Each signed-in user has their own broker session (ADR 0008, #585), so RPMS acts as that user.
- A failed read is a typed error (#579). It becomes an `OperationOutcome` on the FHIR API and a visible message in the UI. It never becomes an empty list.
- No catch-all `rescue` in a request path. A convention test enforces this for FHIR searches (#656); extend it to every controller action.

**Today.** The one-door rule holds (`BackendRegistryConventionTest`). One shared broker client serves every user (#585), and several reads still turn failures into empty data (#579).

**Next.** #585, then #579.

## 3. Authorization comes from RPMS facts, through one table this engine owns

**Why.** A site manages access in RPMS, with Kernel's tools. A second, separate permission system would need its own administration and would drift from RPMS.

**In practice.** ADR 0010:
- options (Kernel's access rule) and security keys map to named capabilities, and capabilities map to SMART scopes;
- the server enforces every capability;
- views show and hide controls from the same capability set;
- a failed read of the user's options or keys refuses the sign-on.

Pundit stays as the enforcement mechanism (ADR 0001), but policies ask about capabilities, not keys or user classes.

**Supersedes** the part of ADR 0001 that put key-to-capability mappings in rpms-rpc. rpms-rpc now reports facts, and the host owns policy (rpms-rpc ADR 0010).

**Today.** Every live sign-on gets empty scopes (#578), and two authorization models run side by side.

**Next.** ADR 0010, then #578.

## 4. Follow the current federal baseline: FHIR R4, US Core 6.1.0, SMART App Launch v2

**Why.** As of 2026-01-01 the ONC certification baseline is:

- USCDI v3 with US Core 6.1.0;
- SMART App Launch v2, which replaces v1.

CMS Aligned Networks ask for a US Core FHIR API with USCDI v3 or later.
The HTI-5 proposal would remove many certification criteria but keeps the FHIR API criterion, (g)(10).
Building to (g)(10) is therefore the durable bet; building to criteria that may be removed is not.

**In practice.**
- Mint SMART v2 scopes (`user/Observation.rs`, `user/Patient.cruds`). Accept v1 scopes from older clients only by translating them to v2 at the edge.
- Declare US Core 6.1.0 in the CapabilityStatement (`implementationGuide`), and only for resources that actually conform.
- Validate FHIR output against US Core in CI with the HL7 validator, and run Inferno's (g)(10) suite against a deployed stack (#254). Hand-written serializers are fine; unvalidated ones are not.
- Advertise only what is served, in discovery and in the CapabilityStatement (#657, #658, #656).

**Today.** Scopes are SMART v1, there is no implementation-guide declaration, and FHIR output is validated by unit tests only.

**Next.**
1. Move to v2 scopes along with #578.
2. Add the validator to CI.
3. Fix #657 and #658.

## 5. Browsers hold a session cookie; API clients hold short-lived, sender-constrained tokens

**Why.** A token in a browser can be stolen by any script on the page. A server-side session behind an `HttpOnly`, `SameSite` cookie can't. API clients are a different audience, with different needs.

**In practice.**
- The browser gets a server-side session behind a cookie (the "backend for frontend" pattern). Nothing in the browser can act on its own as the user.
- Third-party clients follow OAuth 2.1 practice:
  - authorization code with PKCE, and no implicit flow;
  - backend services authenticated with asymmetric client assertions (already in place);
  - RFC 9068 JWT access tokens with short lifetimes;
  - refresh tokens that rotate;
  - DPoP (RFC 9449) for public clients when SMART launch is served.
- Tokens carry capabilities and scopes, never raw RPMS key names (ADR 0010).

**Today.** The browser session and the backend-services path follow this. SMART launch is advertised but not served (#657).

**Next.** Serve SMART launch, or stop advertising it.

## 6. Staff sign in with the organization's identity provider and phishing-resistant MFA

**Why.** Access and verify codes typed into a web form are the weakest part of this system's perimeter. Phishing-resistant MFA (passkeys, FIDO2 security keys) is the 2026 baseline for clinical systems.

**In practice.**
- Sign-on goes through the organization's IdP (OIDC), with MFA enforced there.
- RPMS still decides what the user may do (principle 3).
- How the server then acts in RPMS as that person, without storing their codes, is #531.
- The access/verify form stays only until #531 lands, and only over TLS.

**Today.** Access/verify codes through the login form.

**Next.** The #531 ADR.

## 7. Patient-level rules are checked on every read, not encoded as scopes

**Why.** Scopes say what kind of data a user may see. Whether this user may open this patient (sensitive or restricted records, Part 2) depends on the patient, and RPMS logs it.

**In practice.**
- Every path that returns a patient's data runs the sensitive-record check and log (#613), not only patient select.
- Part 2 content is segmented at the record level (ADR 0006, #494).
- There are no clinic, ward or institution scopes. RPMS has no such restriction on reading a chart; "my clinic's patients" is a list filter, not a permission. Division (`DUZ(2)`) is a default, not a boundary (ADR 0007).

**Today.** Not built (#613, #494).

## 8. Every access to PHI is recorded, and the record can't be quietly changed

**Why.** It's required (HIPAA's audit controls), and it's how a site answers "who looked at this chart".

**In practice.**
- The audit row is written before the response leaves, and the request fails if it can't be (ADR 0005).
- Logs carry no PHI: identifiers and outcome codes, never free text from RPMS or exception messages.
- Responses that carry PHI are `Cache-Control: no-store`.

**Today.** In place, with tamper-evidence work open (#506, #518).

## 9. Use Rails' own 2026 tools before adding gems

**Why.** Every gem is a dependency to patch and audit in a system holding PHI. Rails 8.1 ships most of what this engine needs.

**In practice.**

| Need | Rails' own tool |
|---|---|
| Rate limiting (#498) | `rate_limit` in controllers, with a convention test that every route is covered |
| Encryption of PHI-bearing columns in PostgreSQL | Active Record encryption (`encrypts`) |
| Background work | Solid Queue; a job carries the identity and scope it was granted (ADR 0009) |
| Structured, PHI-free telemetry | Rails 8.1's event reporting |
| Content Security Policy | strict CSP with nonces, from the engine's install generator, since the host app owns the setting |

- Test on the Ruby versions CI runs (3.4 and 4.0), and keep `rails` current within 8.1.

**Today.** None of the table is in use. The CSP initializer in the test host is commented out.

**Next.**
1. Rate limiting (#498).
2. A CSP for the engine's pages.
3. A decision on which PostgreSQL columns hold PHI.

## 10. Server-rendered HTML with Hotwire, accessible to WCAG 2.1 AA

**Why.** Clinicians need fast pages that work on clinic hardware, and HHS's Section 504 rule requires WCAG 2.1 AA for recipients' web content. The compliance date was reportedly moved to May 2027 for larger recipients; confirm the date in the Federal Register.

**In practice.**
- Views are ERB templates and partials, not HTML built in Ruby (`content_tag` chains, `render html:`).
- One attribute per line, and one sentence per line in text content, for readable diffs.
- Turbo and Stimulus for interactivity, Tailwind for styling (#547).
- A single-page app only if a screen proves it needs one.
- Accessibility is checked in system tests (axe), not at the end.

**Today.** About ten ERB views; the clinician UI is still VueCentric (ADR 0004).

**Next.** Add an accessibility check to the system-test helper as the first web screens land.

## 11. Tests prove behaviour against the real thing

**Why.** A mock RPMS accepts anything, so a mock-only suite passes while the real broker refuses the call. This happened with sign-on (#539), with CIA replies, and with clinic names in booking (#570).

**In practice.**
- Unit tests run on inputs captured from a real RPMS, not on invented ones.
- Each user story has an application-level test that signs on as its persona against a container of the pinned RPMS build and walks the story. Each test names its rpms-ux scenario id.
- Convention tests read the routing table or parse the source, so a new route or controller is covered without editing a list.
- A new test is shown to fail on the code it fixes before it is trusted.

**Today.** The suite is mostly mock-backed. `test/system/live` exists for sign-on.

**Next.** A live persona test per story, starting with #576.

## Not doing, and why

- **No copy of RPMS clinical data in PostgreSQL** (principle 1).
- **No permissions keyed by clinic, ward or institution** (principle 7).
- **No site-configurable per-screen permissions** like VueCentric's object registry. On a current build, 3 of 189 screen objects use it. Those three rules become ordinary capabilities (ADR 0010).
- **No tokens in browser storage** (principle 5).
- **No work on certification criteria the HTI-5 proposal would remove**, until the final rule says otherwise.

## Decisions for the team

1. Adopt this page as the yardstick for reviews, and link it from the README.
2. Amend ADR 0001: Pundit stays, but mappings move from rpms-rpc to this engine (principle 3).
3. Move scopes to SMART v2 as part of #578 (principle 4).
4. Name the PostgreSQL columns that hold PHI, and encrypt them (principle 9).
5. Choose the #531 sign-on design: how the server acts in RPMS as an IdP-authenticated user (principle 6).

## References

- ONC HTI-1 final rule: USCDI v3, US Core 6.1.0 and SMART App Launch v2 as the certification baseline from 2026-01-01.
- ONC HTI-5 proposed rule (comment period closed 2026-02-27; not final as of this writing).
- CMS Interoperability Framework: Aligned Network criteria, US Core FHIR APIs with USCDI v3 or later.
- HHS Section 504 rule (45 CFR 84, Subpart I): WCAG 2.1 AA for web content and mobile apps.
- OAuth 2.1 (draft), RFC 9068 (JWT access tokens), RFC 9449 (DPoP), SMART App Launch v2.
- ADRs 0001 to 0007 on `main`; ADRs 0008 and 0009 (PR #594); ADR 0010 (PR #662).
