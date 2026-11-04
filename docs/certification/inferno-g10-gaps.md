# Inferno (g)(10): what the test kit asks, and what lakeraven-ehr serves

The ONC Certification (g)(10) Standardized API test kit has never been run against this engine (#261).
This maps each of its test groups to what `main` serves, from the code and the tests, not from other docs.
Read on 2026-11-03 against test kit **v8.1.0** (us_core_test_kit 1.2.0, smart_app_launch_test_kit 1.0.3), suite options US Core 6.1.0, SMART App Launch 2.0.0, Bulk Data 2.0.0.
The deployed stack's `/metadata` and `.well-known/smart-configuration` matched `main` that day.

The runbook for running the kit is at the end.

## Summary

| Group | Met | Partial | Missing |
|---|---|---|---|
| 1 Standalone Patient App (full access) | 3 | 1 | 5 |
| 2 Standalone Patient App (limited access) | 0 | 0 | 2 |
| 3 EHR Practitioner App | 0 | 0 | 4 |
| 10 Single Patient API (US Core 6.1.0) | 0 | 12 | 8 |
| Multi-Patient API (Bulk Data) | 3 | 1 | 4 |
| 9 Additional authorization tests | 0 | 1 | 9 |
| 11 Visual inspection and attestation | 1 | 0 | 6 |

The one blocker under everything: the FHIR API controllers have no RPMS connection for a bearer token, so on a live stack every read that reaches RPMS answers 503 (#844).
After that, SMART authorization-code launch (#839) gates groups 1, 2, 3, 9 and 10, because the single-patient API runs on group 1's token.

## Gaps

State: **met** (the kit's check should pass), **partial** (some of it is served), **missing**.
Evidence is file:line on `main`; tests are named where they prove the behaviour.

### 1 Standalone Patient App, full access

| Requirement | State | Evidence | Issue |
|---|---|---|---|
| `.well-known/smart-configuration` served, unauthenticated, JSON | met | `config/routes.rb:105`; `test/controllers/lakeraven/ehr/smart_configuration_controller_test.rb` | |
| `code_challenge_methods_supported` includes S256 | met | `app/services/lakeraven/ehr/smart_discovery.rb:47` | |
| `authorization_endpoint`, authorization-code grant, confidential symmetric client, PKCE S256 | missing | no authorize route (`config/routes.rb:105-109`); `GRANT_TYPES = client_credentials` (`smart_discovery.rb:25`) | #839 |
| Capabilities: `launch-standalone`, `context-standalone-patient`, `permission-patient`, `permission-offline`, `client-public`, `client-confidential-symmetric`, `sso-openid-connect`, `authorize-post` | missing | `smart_discovery.rb:29` lists `client-confidential-asymmetric permission-v1 permission-v2` only (correct: nothing else is served, #657) | #839 |
| Scopes `launch/patient openid fhirUser offline_access` + `patient/X.rs` for 26 USCDI types granted, v2 syntax | partial | v2 scopes and v1 translation exist (`SmartScope`, #665); no `patient/` grant path and most types not served | #839, #848, #849 |
| OpenID Connect: `openid-configuration`, JWKS, RS256 `id_token`, `fhirUser` resolves | missing | none routed | #841 |
| Token refresh with and without `scope`; invalid refresh refused | missing | no refresh tokens (`BackendServicesController::TOKEN_LIFETIME` 5 min, no `refresh_token`) | #840 |
| Request without a token gets 401 | met | `SmartAuthentication#authenticate_smart_token!`; `test/controllers/lakeraven/ehr/smart_auth_test.rb` | |
| Unrestricted access: a patient search succeeds for every USCDI type | missing | 503 for bearer tokens (`application_controller.rb:104`); 14 types not routed | #844, #849 |

### 2 Standalone Patient App, limited access

| Requirement | State | Evidence | Issue |
|---|---|---|---|
| User deselects resource types on an authorization screen | missing | no authorization screen | #843 |
| Granted types readable, others refused | missing | per-type scope checks exist (`ApplicationController#authorize_fhir_scope!`), but no launch issues a patient token | #843, #839 |

### 3 EHR Practitioner App

| Requirement | State | Evidence | Issue |
|---|---|---|---|
| EHR launch from Inferno's launch URI to `authorize` (POST), `launch` scope | missing | `smart/launch` exists (`smart_launch_controller.rb`) but redirects to `oauth/authorize`, which is not routed; hardcodes `patient/*.rs` (`smart_launch_controller.rb:47`) | #839 |
| Capabilities `launch-ehr`, `context-ehr-patient`, `context-ehr-encounter`, `context-banner`, `context-style`, `permission-user` | missing | not served, not advertised | #839 |
| Token response `patient`, `encounter` (readable), `need_patient_banner`, `smart_style_url` | missing | `LaunchContext` model exists, no token response carries it; Encounter has no read | #839, #845 |
| `user/X.rs` scopes, OIDC, refresh | missing | as group 1 | #839, #840, #841 |

### 10 Single Patient API, US Core 6.1.0

| Requirement | State | Evidence | Issue |
|---|---|---|---|
| CapabilityStatement: FHIR 4.0.1, JSON, US Core IG, every USCDI type claimed | partial | `app/services/lakeraven/ehr/fhir/capability_statement.rb:24-25,129-130`; 12 of 26 types claimed; `test/integration/capability_statement_test.rb` | #849, #334 |
| Patient: read; `_id`, `identifier`, `name`, `birthdate+name`, `gender+name` | partial | read and `_id`/`name`/`birthdate`/`gender` (`search_capabilities.rb:60-75`); `identifier` resolves SSN only and is undeclared | #846 |
| AllergyIntolerance: `patient`, read | partial | search `allergy_intolerances_controller.rb`; read always 404; `clinical-status` added in #852 | #845 |
| Condition (problems/health concerns): `patient`, `patient+category`, read | partial | `patient`; `category` and `clinical-status` added in #852; read always 404 | #845 |
| Condition encounter-diagnosis profile | missing | `Condition.from_rpms_row` sets `problem-list-item` only (`condition.rb:72`) | #848 |
| MedicationRequest: `patient+intent`, `patient+intent+status`, read; Medication by reference | partial | `intent` added in #852; `status` refuses `system|code`; read always 404; no Medication | #846, #845, #849 |
| Observation vital-signs profiles: `patient+category`, `patient+code`, `patient+category+date`, read | partial | `category`, `code` (`search_capabilities.rb:105-118`) refuse `system|code`; no `date`; read always 404 | #846, #845 |
| Observation lab, clinical-result, smoking status, screening-assessment, occupation, pregnancy, pediatric vitals | missing | Observation declares `us-core-vital-signs` only (`capability_statement.rb:41`) | #848 |
| Encounter: `_id`, `patient`, `date+patient`, read | partial | `patient` only; entries are backend rows, not a US Core Encounter; no read (`routes.rb:75`) | #845, #846 |
| Immunization, Procedure: `patient`, (`patient+date`), read | partial | `patient` only; no read (`routes.rb:79-80`) | #845, #846 |
| ServiceRequest: `_id`, `patient`, `patient+category`, `patient+code`, `patient+category+authored`, read | partial | `patient` only; no read (`routes.rb:78`) | #845, #846 |
| Location `name`, `address`; Organization, Practitioner read | partial | reads served (`routes.rb:70,76-77`); Location has no search | #846 |
| CarePlan, CareTeam, Goal | missing | models exist, not routed | #330, #334 |
| Coverage | missing | not routed as FHIR Coverage | #239 |
| Implantable Device | missing | not routed; RPMS UDI source unknown | #331, #334 |
| DiagnosticReport (lab, note), DocumentReference | missing | not routed | #249, #334 |
| MedicationDispense, QuestionnaireResponse, RelatedPerson, Specimen, PractitionerRole | missing | not routed | #849, #367 |
| `_revinclude=Provenance:target` on every profile search; Provenance read | missing | declared on Patient only (`search_capabilities.rb:74`); no Provenance route | #847 |
| Must-support coverage across the test patients (USCDI v3 elements) | partial | CI validates the served types against US Core 6.1.0 (`.github/workflows/ci.yml` job "US Core 6.1.0 validation"), but validation is not must-support coverage | #360, #564 |
| Reference resolution | partial | Patient, Practitioner, Organization, Location readable; Encounter, Medication not | #845, #849 |

### Multi-Patient API (Bulk Data 2.0.0)

| Requirement | State | Evidence | Issue |
|---|---|---|---|
| Backend Services token: `client_credentials`, `private_key_jwt`, JWKS by URL | met | `backend_services_controller.rb:36-113,131`; `test/controllers/lakeraven/ehr/backend_services_controller_test.rb` | |
| Refuses bad `grant_type`, bad `client_assertion_type`, bad JWT; response has `access_token`, `token_type`, `expires_in`, `scope` | met | `backend_services_controller.rb:37-46,104-109` | |
| Signing algorithm the kit offers (RS384 or ES384) | met | `ALLOWED_ALGORITHMS = RS384` (`backend_services_controller.rb:25`); the tester picks RS384 | |
| CapabilityStatement declares Group `export` operation | missing | not declared, no Group | #216 |
| `GET Group/{id}/$export` with `Accept`/`Prefer: respond-async`, 202 + `Content-Location` | missing | export is `POST /exports` for one patient, defaulting to patient 1 (`exports_controller.rb:95`) | #216, #237 |
| Status polling 202 then 200 manifest with absolute `url`s, `requiresAccessToken`; DELETE cancels then 404 | partial | `exports_controller.rb` show/destroy exist on `/exports/:id`; not the Bulk Data shapes | #216 |
| NDJSON for every US Core type across at least two patients | missing | `EhiExportService::FHIR_RESOURCE_TYPES` is 5 types, one patient | #216, #849 |
| `system/` token reads RPMS | missing | 503: no service account (ADR 0011 §6) | #844 |

### 9 Additional authorization tests

| Requirement | State | Evidence | Issue |
|---|---|---|---|
| 9.2 Public client standalone launch | missing | | #839 |
| 9.3 Token revocation: revoked token and its refresh token refused | partial | revoked tokens are refused on reads (`smart_authentication.rb:42`); no way to revoke a patient's grant, no refresh token | #842, #840 |
| 9.4 Invalid `aud` gets no code | missing | | #839 |
| 9.6 Bad code and bad `client_id` refused at token endpoint | missing | | #839 |
| 9.7 PKCE S256 required (no / blank / wrong / plain verifier refused) | missing | | #839 |
| 9.9 EHR launch with patient scopes | missing | | #839 |
| 9.11 Token introspection | missing | no `introspection_endpoint` | #842 |
| 9.12 Asymmetric client launch | missing | the asymmetric assertion exists for Backend Services only | #839 |
| 9.13 v1 scopes granted | missing (translation done) | v1 to v2 translation exists (#665); needs a launch | #839 |
| 9.14, 9.15 Fine-grained and granular category scopes | missing | | #843 |

### 11 Visual inspection and attestation

| Requirement | State | Evidence | Issue |
|---|---|---|---|
| TLS 1.2 or higher | met | the deployed stack serves HTTPS with a trusted certificate (#261 comment, 2026-11-03); attest | |
| Test01/02 registration documented; Test07/09 public, complete documentation; public base-URL list | missing | | #850 |
| Test03 authorization screen; Test04 patient told of `offline_access` | missing | | #843, #840 |
| Test05/13 and refresh attestation: refresh tokens of at least 3 months, issued to native apps | missing | | #840 |
| Test08 multi-patient data no greater than pre-authorized scopes | missing | depends on Group export | #216, #850 |
| Test10 JWKS not cached past cache-control | missing | `ClientJwks` caches for a fixed TTL (`client_jwks.rb:50`) | #850 |
| Bulk `_since` semantics | missing | `_since` refused today (`exports_controller.rb`, `render_since_unsupported`) | #216, #850 |

## RPMS limits

Some US Core data has no RPMS source the engine reads today. Each is recorded in its issue, not worked around with our own M code:
- Provenance: RPMS keeps none; it is derived from the entering user, facility and date (#847).
- MedicationDispense: pharmacy is out of scope for this deployment (#849).
- Specimen, lab results: need an RPMS lab read in rpms-rpc (#848, #849).
- Implantable device UDI, occupation, pregnancy intent: no known RPMS field (#331, #848).

## Runbook: running the kit against a deployed stack

For a person to run: an agent cannot start Inferno or sign in.

### 1. Choose an Inferno

- **Hosted (recommended):** https://inferno.healthit.gov/suites/g10_certification.
  Its base URL is `https://inferno.healthit.gov/suites`, so its URIs are:
  - redirect `https://inferno.healthit.gov/suites/custom/smart/redirect`
  - launch `https://inferno.healthit.gov/suites/custom/smart/launch`
  - Bulk Data JWKS `https://inferno.healthit.gov/suites/custom/g10_certification/.well-known/jwks.json`
  The stack fetches that JWKS when Inferno asks for a Backend Services token, so it has to reach it; the hosted instance satisfies that.
- **Local:** clone https://github.com/onc-healthit/onc-certification-g10-test-kit at tag `v8.1.0`, then run its `setup.sh` and `run.sh` (Docker) and open `http://localhost`.
  The URIs become `http://localhost/custom/...`, and the stack cannot fetch a JWKS on `localhost`, so the Bulk Data group needs the hosted instance or a tunnel.
  Terminology validation needs a UMLS key (the kit's README, "Terminology Support"); without it, binding checks are skipped.

Pick suite options **US Core 6.1.0**, **SMART App Launch 2.0.0**, **Bulk Data 2.0.0**.

### 2. Register the clients

Clients are Doorkeeper applications (`oauth_applications`). There is no admin screen; register them with a one-off runner on the app host, for example `bin/rails runner register_inferno_clients.rb`, with:

```ruby
# Backend Services client for the Multi-Patient API (works today).
Doorkeeper::Application.create!(
  name: "Inferno g10 bulk",
  uid: "inferno-g10-bulk",
  redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
  confidential: true,
  jwks_uri: "https://inferno.healthit.gov/suites/custom/g10_certification/.well-known/jwks.json",
  scopes: "system/*.rs",
  organization_id: "<the deployment's organization id>"
)
```

- `uid` is the `client_id` Inferno uses as the assertion's `iss` and `sub`.
- `organization_id` must be set, and must be the same organization as every other backend client, or the token endpoint refuses (`client_not_bound_to_organization`, `multiple_organizations_unsupported`).
- Select **RS384** in Inferno: the token endpoint accepts RS384 only.
- `redirect_uri` is unused by Backend Services; the out-of-band value is what the engine's own tests register (`backend_services_controller_test.rb`).

The confidential launch client (groups 1, 2, 3, 9) cannot be registered usefully until #839 serves an authorization endpoint.
When it does, it will need, at least:
- a confidential symmetric client (`client_id`, `client_secret`) with redirect URI `https://inferno.healthit.gov/suites/custom/smart/redirect` and launch URI `https://inferno.healthit.gov/suites/custom/smart/launch`;
- a public client for 9.2 and an asymmetric client (JWKS `https://inferno.healthit.gov/suites/custom/smart_stu2/.well-known/jwks.json`) for 9.12.

### 3. The inputs Inferno asks for

| Input | Value |
|---|---|
| FHIR endpoint (`url`) | `https://ehr.rpms.lakeraven.com/lakeraven-ehr` |
| Standalone / EHR / public / asymmetric client: `client_id`, `client_secret`, requested scopes | from step 2 once #839 lands; Inferno pre-fills the default scopes |
| `expected_resources` (limited access) | default `patient, condition, observation` |
| `additional_patient_ids` | synthetic demo patients that together cover every must-support element |
| `implantable_device_codes` | blank until Device is served |
| Bulk `token_url` | `https://ehr.rpms.lakeraven.com/lakeraven-ehr/oauth/token` |
| Bulk `client_id`, encryption method | `inferno-g10-bulk`, RS384 |
| Bulk scope | `system/*.rs` (or `system/*.read`, translated) |
| Bulk `bulk_server_url`, `group_id`, `bulk_patient_ids_in_group` | blank until #216 serves Group export |
| `bulk_timeout`, `lines_to_validate` | defaults (180 s, 100) |
| Introspection endpoint and authorization header | blank until #842 |

### 4. What to expect today

Discovery, `/metadata`, and the Backend Services token tests should pass.
Every group that needs a launched token will stop at the authorization step (#839), and every data read on a bearer token will answer 503 until #844.
Run the whole suite once anyway, unchanged, and keep the report (JSON export) as the baseline under #261 and #404.
