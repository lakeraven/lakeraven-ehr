# FHIR API

lakeraven-ehr serves a FHIR R4 API over RPMS, and each deployment publishes its own endpoints.
This page tells an app developer how to find them, how to register an app, and how to read.

## Endpoints

Every path below sits under the deployment's mount, which the sample host app sets to `/lakeraven-ehr`.
The service base URL is `https://<deployment host>/lakeraven-ehr`.

| Path | What it gives you | Sign-in |
|---|---|---|
| `/metadata` | The CapabilityStatement: every type, interaction and search parameter served | None |
| `/.well-known/smart-configuration` | The SMART endpoints, capabilities and auth methods | None |
| `/oauth/authorize` | SMART App Launch authorization, GET or POST | The user's RPMS sign-on |
| `/oauth/token` | Tokens for a launched app and for Backend Services | Client authentication |

Read `/metadata` and `.well-known/smart-configuration` as the source of truth: they are built from what the running version serves, so they never claim more than it does.

## Register an app

A deployment's operator registers each app, and there is no self-service sign-up yet.
Send the operator:

- the app's name;
- its redirect URI, and its launch URI if it supports EHR launch;
- how it authenticates (below);
- the scopes it needs;
- for a key-based client, an HTTPS `jwks_uri` on a publicly routable host.

The operator gives you back a `client_id`, and a `client_secret` if you chose one.

| Client type | How it authenticates |
|---|---|
| Public | `client_id` and PKCE alone |
| Confidential symmetric | `client_secret`, by HTTP Basic or in the request body |
| Confidential asymmetric | A JWT signed with RS384 or ES384, verified against your `jwks_uri` |
| Backend Services (multi-patient) | A JWT signed with RS384, verified against your `jwks_uri` |

The server honours your JWKS `Cache-Control`, up to five minutes, so a rotated key takes effect within that time.

## Launch an app for one user

1. Send the user to `/oauth/authorize` with PKCE S256, which is required for every client.
2. The user signs in with their own RPMS codes and approves what the app may do.
3. For a standalone launch with `launch/patient`, the user picks a patient.
4. Exchange the code at `/oauth/token`.

The token response carries `patient`, `need_patient_banner` and `smart_style_url`.
What the app can read is what it asked for, within its registration, within that user's RPMS access.

A launched token lasts up to an hour, and it ends when the user signs out or their session times out.
Refresh tokens and OpenID Connect are not served yet.

Scopes use SMART v2 form (`patient/Observation.rs`), and v1 scopes are accepted and translated.

## Read many patients

Backend Services clients use the `client_credentials` grant with a signed JWT, and a token lasts five minutes.
Bulk export needs a service account on the deployment's RPMS, which is not wired yet, so those reads answer 503 today.

## Search

- Results come back as a `searchset` Bundle, 20 to a page by default and 100 at most.
- `_count`, `_offset`, `_sort`, `_include`, `_revinclude` and `_elements` are served where `/metadata` declares them.
- Token parameters take `code`, `system|code`, `|code` or `system|`.
- Date parameters take a prefix (`eq`, `ne`, `gt`, `lt`, `ge`, `le`, `sa`, `eb`) and a date of any precision; repeat the parameter for a range.
- A value the server cannot apply gets a 400 OperationOutcome that says why, so a result is always the search you sent.
- Most clinical types need `patient`, and a token bound to one patient reads only that patient.

## Errors

Every refusal is an OperationOutcome.

| Status | Meaning |
|---|---|
| 400 | The search has a value the server does not support |
| 401 | The token is missing, expired or revoked |
| 403 | The token's scope or patient does not cover this read |
| 404 | No such record, or the type has no read by id yet |
| 429 | Too many requests: wait and retry |
| 503 | RPMS could not answer: nothing was read, so retry later |

## Transport

Deployments serve the API over TLS 1.2 or higher.
Certification status and the open gaps are in [`certification/inferno-g10-gaps.md`](certification/inferno-g10-gaps.md).
