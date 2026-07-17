# Adapter Notes

This document records implementation decisions for the FHIR adapters that
surface RPMS and VistA data as FHIR R4 resources.

## US Core Validation

### Decision

We enforce a lightweight, dependency-free US Core conformance check at the
adapter boundary rather than relying on an external validator.

### Why not fhir_models or Inferno?

- `fhir_models` validates FHIR R4 syntax but does not ship with the US Core
  Implementation Guide; loading the IG package adds complexity we are not ready
  to maintain.
- `inferno_core` is a test-execution framework, not a drop-in validator, and
  pulls in many dependencies.
- An external HAPI validator requires a JVM process and is too heavy for the
  engine test suite.

### What we validate

`Lakeraven::EHR::FHIR::UsCoreValidator` checks the resources this engine
produces:

- **Patient** (`us-core-patient`)
  - `resourceType`, `id`, `name`, `gender`
  - US Core `race`, `ethnicity`, and `birthsex` extensions are present and
    contain a valid sub-extension/value
- **Practitioner** (`us-core-practitioner`)
  - `resourceType`, `id`, `name`
  - at least one `identifier`
- **Observation** (US Core vital sign profiles)
  - `resourceType`, `id`, `status`, `code`, `category`, `subject`,
    `effectiveDateTime`
  - blood pressure resources must have systolic and diastolic `component`s

The validator only inspects resources that declare a US Core `meta.profile`.
Messages report missing structural elements only and never include PHI
(e.g. names, identifiers, dates, or values).

### Enabling validation

Validation is off by default in production and enabled in tests:

```ruby
# config/initializers/lakeraven_ehr.rb (host app)
Lakeraven::EHR.configure do |config|
  config.validate_fhir_us_core = true
end
```

When enabled, the following adapters call `UsCoreValidator.validate!` after
building a FHIR hash:

- `Lakeraven::EHR::FHIR::PatientSerializer`
- `Lakeraven::EHR::FHIR::PractitionerSerializer`
- `Lakeraven::EHR::Observation#to_fhir`

Failures raise `Lakeraven::EHR::FHIR::UsCoreValidationError`, which can be
mapped to a FHIR `OperationOutcome` by the controller layer.

### Known limitations

- This is a focused, structural validator. It does not replace a full FHIR
  profile validator and should be treated as a guard rail, not a certification
  tool.
- `Patient.birthDate` is not enforced by the validator even though US Core
  marks it required. In practice VistA/RPMS always returns a DOB, but unit
  tests construct patients without one; requiring it would break those tests.
- Search parameter support is validated only by the existing request specs and
  ONC feature tests, not by `UsCoreValidator`.
