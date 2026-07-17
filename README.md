# Lakeraven::Ehr
Short description and motivation.

## Usage
How to use my plugin.

## Installation
Add this line to your application's Gemfile:

```ruby
gem "lakeraven-ehr"
```

And then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install lakeraven-ehr
```

## Contributing
Contribution directions go here.

## SMART on FHIR authorization

The engine validates OAuth2 bearer tokens (Doorkeeper) on every FHIR
endpoint and enforces SMART App Launch v1 scopes
(`patient/*.read`, `user/*.read`, `system/*.read`, per-resource variants).

### Host app Doorkeeper configuration

The host application owns the Doorkeeper initializer. Configure the SMART
scope set and refresh tokens as in `test/dummy/config/initializers/doorkeeper.rb`:

```ruby
Doorkeeper.configure do
  orm :active_record
  default_scopes "system/*.read"
  optional_scopes "openid", "fhirUser",
                  "launch", "launch/patient", "offline_access",
                  "patient/*.read", "patient/*.*",
                  "patient/Patient.read", "patient/Condition.read",
                  "patient/Observation.read", # ...per-resource scopes
                  "user/*.read", "user/*.*",
                  "system/*.read", "system/*.write", "system/*.*"
  grant_flows %w[authorization_code client_credentials refresh_token]
  use_refresh_token
end
```

### Launch context (VistA/CPRS EHR launch)

When a CPRS/EHR user launches a SMART app, the host app mints a launch
context bound to the OAuth client and the in-context patient:

```ruby
Lakeraven::EHR::LaunchContext.mint(
  oauth_application_uid: app.uid,
  patient_dfn: dfn,        # identifier token only — never name/DOB
  encounter_id: encounter_id
)
```

The client passes the launch token to `POST /oauth/token`; the engine
validates client binding and expiry, binds the patient DFN to the token,
and returns `patient`/`encounter` in the token response. Patient-scoped
tokens are restricted to the bound patient's compartment on every
patient-search endpoint.

### Token introspection and refresh

`POST /oauth/introspect` (RFC 7662) reports `active`, `scope`, `client_id`,
`exp`, and launch context. `grant_type=refresh_token` rotates the refresh
token and preserves launch context. Token issuance and refresh write
PHI-safe security `AuditEvent` rows (hashed client identifiers only).

## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
