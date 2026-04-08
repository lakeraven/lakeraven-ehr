# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-04-08

Initial release. A Rails 8.1 mountable engine that exposes a
SMART-on-FHIR read API over a VistA/RPMS backend via an adapter
contract. Ships with 216 unit tests, 40 Cucumber scenarios, and a
no-offenses RuboCop baseline.

### Added

#### Engine foundation

- `Lakeraven::EHR` mountable engine (capitalized acronym, per the
  house naming convention)
- Configuration hooks for `adapter`, `resource_owner_authenticator`,
  `admin_authenticator`, `tenant_resolver`, and `facility_resolver`
- `Lakeraven::EHR::Current` request store with `with_tenant` block
  helper and `MissingTenantContextError`
- `ApplicationController` base with tenant-resolver integration and
  FHIR `application/fhir+json` `OperationOutcome` error rendering

#### Adapter contract

- `Lakeraven::EHR::Adapters::Base` — abstract contract with
  `search_patients`, `find_patient`, `search_practitioners`, and
  `find_practitioner`
- `Lakeraven::EHR::Adapters::MockAdapter` — in-memory implementation
  for tests; mints opaque `pt_*` and `pr_*` identifiers

#### Service layer

- `Lakeraven::EHR::PatientSearch` — tenant-scoped search service
- `Lakeraven::EHR::ProviderSearch` — tenant-scoped search service

#### FHIR HTTP layer

- `FHIR::PatientSerializer` — US Core R4 Patient resource with
  `HumanName`, `Identifier`, gender, birthDate, and the US Core
  profile meta
- `FHIR::OperationOutcome` — error response builder with severity
  validation
- `FHIR::AuditEventSerializer` — FHIR R4 AuditEvent resource with
  opaque `aud_*` identifiers
- `PatientsController#show` — `GET /Patient/:identifier` under the
  engine mount, Bearer-authenticated, scope-checked, patient-context
  enforced
- `AuditEventsController#index` — `GET /AuditEvent` with tenant
  scoping, entity filtering, `_count` paging, and correct
  `Bundle.total`

#### SMART on FHIR

- Doorkeeper ~> 5.9 configured for SMART scopes, PKCE, refresh
  tokens, and `api_only` mode with hashed token/secret storage
- `.well-known/smart-configuration` discovery endpoint with capability
  and scope advertisement
- `Lakeraven::EHR::SmartAuthentication` controller concern with
  `authenticate_smart_token!`, `authorize_scope!`, and
  `authorize_patient_context!`; wildcard-safe scope matching that
  refuses to let `*.read` satisfy a `*.write` requirement
- `Smart::TokensController` — extends `Doorkeeper::TokensController`
  to embed SMART launch context (`patient`, `encounter`) into the
  token response when a `launch` parameter resolves to an active
  binding
- `Lakeraven::EHR::LaunchContext` — persistent SMART EHR launch
  binding, tenant-scoped, OAuth-client-bound, single-use, 10-minute
  default TTL. Opaque `lc_*` launch tokens, unique-indexed

#### PHI audit logging

- `Lakeraven::EHR::AuditEvent` — FHIR R4 AuditEvent rows, immutable
  per HIPAA § 164.312(b), tenant-scoped, opaque-identifiers only
  (no PHI columns)
- `AuditableClinicalAccess` controller concern with
  `audit_clinical_access only: :show`-style declaration; automatic
  after_action capture of every authenticated PHI-touching request

#### Architecture documentation

- ADR 0001: Engine scope (what's in, what's out)
- ADR 0002: PHI tokenization (zero PHI at rest)
- ADR 0003: Two-level tenancy (tenant + facility, row-based, fail-loud)
- ADR 0004: Identifier convention (`id` vs `identifier`)
- ADR 0005: SMART launch grant types (`authorization_code` +
  `client_credentials` both supported)

### Notes

- Requires Ruby 3.4+ and Rails 8.1+
- Runtime dependencies: `rails >= 8.1.3`, `rpms-rpc ~> 0.1`,
  `doorkeeper ~> 5.9`
- `rpms-rpc` is pulled from its git tag until it lands on rubygems.org
- Test suite is hermetic — no sockets, no live VistA broker, no PHI
- CI runs unit tests, Cucumber features, Zeitwerk eager-load check,
  and RuboCop on Ruby 3.4 with PostgreSQL 16 on every push and PR
