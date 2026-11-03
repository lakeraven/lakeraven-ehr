# Inbound referral intake

External systems submit a FHIR R4 `ServiceRequest` into a local intake queue. Staff triage and patient matching happen later. This slice does not call RPMS.

The engine is mounted at a host-chosen path. The examples below use `/lakeraven-ehr`, which is the dummy app's mount.

## Endpoint

`POST /lakeraven-ehr/ServiceRequest`

`Content-Type` must be `application/fhir+json` or `application/json`. Any other media type is **415** with an OperationOutcome, and nothing is stored.

The body is one ServiceRequest resource. A Bundle is not accepted.

Authenticate with a SMART backend-services token (`client_credentials` at the token endpoint). Send it as `Authorization: Bearer <token>`.

## Scope

The token must be a pure system token. ServiceRequest create must come from a `system/` scope, and the token must carry no `patient/` scope and no `user/` scope:

- `system/ServiceRequest.c`, or
- `system/ServiceRequest.write` (SMART v1 `.write` includes create)

`system/*.c`, `system/*.write`, and `system/*.*` also grant it, when no `patient/` or `user/` scope is present.

`user/` and `patient/` ServiceRequest write are refused with 403. A system write token mixed with any `patient/` or `user/` scope is refused with 403. A system token has no RPMS session, and a patient or user scope would bind the call to a person this queue does not match yet.

## Required elements

| Element | Rule |
|---|---|
| `resourceType` | `ServiceRequest` |
| `status` | `draft` or `active` |
| `intent` | a FHIR R4 RequestIntent code (`proposal`, `plan`, `directive`, `order`, `original-order`, `reflex-order`, `filler-order`, `instance-order`, `option`) |
| `identifier` | 1 to 20 entries, each with `system` and `value` |
| `subject.identifier` | `system` and `value` (a reference alone is not enough) |
| `code` | a non-blank `text`, or at least one `coding` entry that is an object with a non-blank `code` |

Any other element on the ServiceRequest is stored as submitted. The client's top-level `id` and `meta` are discarded. The response `id` is the queue's id, a UUID.

`subject.identifier` is kept so a later step can match the patient. It is not looked up in RPMS here.

## Idempotency

Uniqueness is per OAuth client (the token's application) and per `identifier.system` + `identifier.value`.

- No stored referral for this client owns any of those identifiers: **201 Created**. The body is the stored ServiceRequest, including the new `id`.
- Every matched identifier belongs to the same stored referral, and `subject.identifier` (`system` and `value`) matches the stored patient identifier: **200 OK** with that original resource. A changed body does not update the stored record. There is no update in this slice. A new identifier sent alongside one that already belongs to that referral is not added.
- The identifiers match two or more stored referrals for this client: **409 Conflict**. Nothing is written.
- The identifiers match exactly one stored referral, but `subject.identifier` differs from the stored patient identifier: **409 Conflict**. Nothing is written.
- The same identifier from a different OAuth client is a different referral.

A concurrent duplicate that loses the unique index is rolled back, then the identifiers are looked up once. Exactly one referral with the same subject returns that resource (200); otherwise 409.

A deadlock rolls the insert back and the whole write is tried once more. That retry waits on the winner's unique-index entry, then finishes as a create (201), a replay (200), or a unique-index collision that is looked up once as above. A second deadlock is 409. Nothing is written on 409.

## Capability

ServiceRequest create belongs to the referrals capability (`prc_referrals`), with ServiceRequest search. A backend that does not provide referrals does not advertise create. `POST /ServiceRequest` from a token that would otherwise be accepted answers **404** with `issue.code` `not-supported`. A token that may not create (no system create permission, or any `patient/` or `user/` scope) is still **403**, including on a backend without referrals.

## Limits

- A `Transfer-Encoding` header (including `chunked`) is **411** when the app still sees it. Some app servers (Puma) de-chunk the body and set `Content-Length` before the app, in which case the size limit applies instead of 411. Clients should send `Content-Length`.
- `Content-Length` greater than 1,048,576 (1 MiB) is **413**, and the body is not read.
- A raw body larger than 1,048,576 bytes is **413** and is not stored. This still applies when `Content-Length` is absent or smaller than the body.
- A body that is not valid UTF-8 is **400** and is not stored.
- `identifier` has at most 20 entries. More than 20 is **422**. The diagnostic is `ServiceRequest.identifier` and does not include submitted values.
- `identifier.value` and `subject.identifier.value` are at most 255 bytes (UTF-8).
- `identifier.system` and `subject.identifier.system` are at most 1024 bytes (UTF-8).
- Any string in the body, including an object key, that contains a NUL (`U+0000`) is **422** and is not stored. The diagnostic is the fixed text `ServiceRequest (string contains NUL)`. It does not include keys, indexes, or any submitted text.
- Any non-finite number in the body (`Infinity` or `NaN`, including a JSON number such as `1e400`) is **422** and is not stored. The diagnostic is the fixed text `ServiceRequest (non-finite number)`. It does not include keys, indexes, or any submitted text.

## Errors

All errors are a FHIR `OperationOutcome`. Validation diagnostics name the element path only (`ServiceRequest.status`, `ServiceRequest.identifier[0].system`). They do not repeat submitted values. A NUL and a non-finite number are the exceptions: their diagnostics are always `ServiceRequest (string contains NUL)` and `ServiceRequest (non-finite number)`, with no key, index, or submitted text.

| HTTP | `issue.code` | When |
|---|---|---|
| 401 | `login` | missing, invalid, or expired token |
| 403 | `forbidden` | the token's ServiceRequest create permission does not come from a `system/` scope, or the token carries a `patient/` or `user/` scope |
| 400 | `invalid` | the body is not valid UTF-8, or not JSON |
| 400 | `structure` | the JSON value is not an object |
| 404 | `not-supported` | this backend does not provide referrals |
| 411 | `structure` | `Transfer-Encoding` is set on the request the app sees. Some app servers (Puma) de-chunk the body and set `Content-Length` before the app, in which case the size limit applies instead of 411. Clients should send `Content-Length`. |
| 413 | `too-costly` | `Content-Length` or the raw body is larger than 1 MiB |
| 415 | `not-supported` | `Content-Type` is not `application/fhir+json` or `application/json` |
| 422 | `invalid` | a required element is missing, not in the value set above, too long, more than 20 `identifier` entries, contains a NUL, or is a non-finite number |
| 409 | `conflict` | the identifiers match more than one stored referral, or one referral whose subject identifier differs, or a second deadlock |

## Example

Synthetic values only.

```http
POST /lakeraven-ehr/ServiceRequest HTTP/1.1
Authorization: Bearer <system token>
Content-Type: application/fhir+json

{
  "resourceType": "ServiceRequest",
  "status": "active",
  "intent": "order",
  "identifier": [
    {
      "system": "https://snf.example.test/referrals",
      "value": "REF-EXAMPLE-0001"
    }
  ],
  "code": {
    "coding": [
      {
        "system": "http://snomed.info/sct",
        "code": "3457005",
        "display": "Patient referral"
      }
    ]
  },
  "subject": {
    "identifier": {
      "system": "https://example.test/mrn",
      "value": "MRN-EXAMPLE-0001"
    }
  }
}
```

A created response uses the same resource, with the queue id:

```json
{
  "resourceType": "ServiceRequest",
  "id": "00000000-0000-4000-8000-000000000001",
  "status": "active",
  "intent": "order",
  "identifier": [
    {
      "system": "https://snf.example.test/referrals",
      "value": "REF-EXAMPLE-0001"
    }
  ],
  "code": {
    "coding": [
      {
        "system": "http://snomed.info/sct",
        "code": "3457005",
        "display": "Patient referral"
      }
    ]
  },
  "subject": {
    "identifier": {
      "system": "https://example.test/mrn",
      "value": "MRN-EXAMPLE-0001"
    }
  }
}
```

Posting that identifier again for the same client returns 200 and this same body, even if `status` or `intent` in the new request differ.

## Audit

The audit entity for create is the queue id. The AuditEvent is `ServiceRequest` plus that id when the intake created or replayed a referral, and `ServiceRequest` with no identifier otherwise. The query string is not consulted. A client `id` in the body is not the audit identifier.

## Not in this slice

- Matching `subject.identifier` to a patient, or creating a patient
- Accepting a Bundle of supporting resources
- Writing the referral to RPMS or RCIS
- Updating or cancelling a stored intake record
