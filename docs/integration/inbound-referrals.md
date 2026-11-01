# Inbound referral intake

External systems submit a FHIR R4 `ServiceRequest` into a local intake queue. Staff triage and patient matching happen later. This slice does not call RPMS.

The engine is mounted at a host-chosen path. The examples below use `/lakeraven-ehr`, which is the dummy app's mount.

## Endpoint

`POST /lakeraven-ehr/ServiceRequest`

`Content-Type: application/fhir+json`

The body is one ServiceRequest resource. A Bundle is not accepted.

Authenticate with a SMART backend-services token (`client_credentials` at the token endpoint). Send it as `Authorization: Bearer <token>`.

## Scope

The token must grant ServiceRequest create from a `system/` scope:

- `system/ServiceRequest.c`, or
- `system/ServiceRequest.write` (SMART v1 `.write` includes create)

`system/*.c`, `system/*.write`, and `system/*.*` also grant it.

The token must not also carry any `patient/` scope. `user/` and `patient/` ServiceRequest write are refused with 403, as is a system write token mixed with a patient scope. A system token has no RPMS session, and a patient scope would bind the call to one patient this queue does not match yet.

## Required elements

| Element | Rule |
|---|---|
| `resourceType` | `ServiceRequest` |
| `status` | `draft` or `active` |
| `intent` | a FHIR R4 RequestIntent code (`proposal`, `plan`, `directive`, `order`, `original-order`, `reflex-order`, `filler-order`, `instance-order`, `option`) |
| `identifier` | one or more entries, each with `system` and `value` |
| `subject.identifier` | `system` and `value` (a reference alone is not enough) |
| `code` | `coding` (non-empty) or `text` |

Any other element on the ServiceRequest is stored as submitted. The client's top-level `id` and `meta` are discarded. The response `id` is the queue's id, a UUID.

`subject.identifier` is kept so a later step can match the patient. It is not looked up in RPMS here.

## Idempotency

Uniqueness is per OAuth client (the token's application) and per `identifier.system` + `identifier.value`.

- No stored referral for this client owns any of those identifiers: **201 Created**. The body is the stored ServiceRequest, including the new `id`.
- Every matched identifier belongs to the same stored referral: **200 OK** with that original resource. A changed body does not update the stored record. There is no update in this slice. A new identifier sent alongside one that already belongs to that referral is not added.
- The identifiers match two or more stored referrals for this client: **409 Conflict**. Nothing is written.
- The same identifier from a different OAuth client is a different referral.

A concurrent duplicate insert is resolved the same way: the loser receives the winner's resource (200) when exactly one referral now matches, otherwise 409.

## Limits

The raw body must be at most 1 MiB (1,048,576 bytes). A larger body is **413** and is not stored.

## Errors

All errors are a FHIR `OperationOutcome`. Validation diagnostics name the element path only (`ServiceRequest.status`, `ServiceRequest.identifier[0].system`). They do not repeat submitted values.

| HTTP | `issue.code` | When |
|---|---|---|
| 401 | `login` | missing, invalid, or expired token |
| 403 | `forbidden` | the token cannot create ServiceRequest as `system/`, or it carries a `patient/` scope |
| 400 | `invalid` or `structure` | the body is not a JSON object |
| 413 | `too-costly` | the body is larger than 1 MiB |
| 422 | `invalid` | a required element is missing or not in the value set above |
| 409 | `conflict` | the identifiers match more than one stored referral for this client |

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

## Not in this slice

- Matching `subject.identifier` to a patient, or creating a patient
- Accepting a Bundle of supporting resources
- Writing the referral to RPMS or RCIS
- Updating or cancelling a stored intake record
