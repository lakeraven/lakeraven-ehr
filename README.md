# lakeraven-ehr

SMART-on-FHIR Rails engine for VistA / RPMS-backed EHRs.

## Status

Pre-1.0 — scaffold landed, feature ports in progress. Each feature
arrives as a self-contained PR backed by a Cucumber BDD scenario set
(see `docs/features.md` for the roadmap).

## What this engine is

A mountable Rails 8.1 engine that provides the data and identity
layer for an EHR running on top of an RPMS / VistA backend:

- **FHIR R4 reads** for `Patient` and `Practitioner`, US Core profile
- **SMART on FHIR** authentication and EHR launch
- **PHI audit logging** with ONC G10 / Inferno compliance in mind
- **Multi-tenant** by tenant + facility (row-based, fail-loud)
- **Adapter-driven** — clinical reads delegate to a configurable
  adapter; the reference implementation calls
  [`rpms-rpc`](https://github.com/lakeraven/rpms-rpc) directly

## What this engine is NOT

- **Not a case-management system.** Case workflows live in
  [`corvid`](https://github.com/lakeraven/corvid), a sibling engine.
  Neither depends on the other; the host SaaS app wires them
  together at the application boundary.
- **Not a PHI store.** The engine ships zero PHI at rest. Patient
  identifiers are stored as opaque tokens; clinical data flows
  through the adapter at request time and is presented as FHIR
  resources without persistence. (See ADR 0002 once published.)
- **Not a billing or claims engine.** Billing, claims, and other
  third-party integrations live in the private host app, not in
  this engine.

## Architecture

```
┌──────────────────────┐
│  lakeraven-ehr-saas  │  (private host app — Jumpstart Pro)
│                      │
│  ┌────────────────┐  │
│  │  lakeraven-ehr │  │  ← this engine
│  │  (FHIR/SMART)  │  │
│  └───────┬────────┘  │
│          │           │
│  ┌───────▼────────┐  │
│  │   rpms-rpc     │  │  ← wire layer to VistA/RPMS
│  └────────────────┘  │
│                      │
│  ┌────────────────┐  │
│  │     corvid     │  │  ← case management (sibling, optional)
│  └────────────────┘  │
└──────────────────────┘
```

## Installation

Add to your `Gemfile`:

```ruby
gem "lakeraven-ehr"
```

Then `bundle install`. Mount the engine in your host app's routes:

```ruby
# config/routes.rb
mount Lakeraven::EHR::Engine => "/ehr"
```

Requires Ruby 3.4+ and Rails 8.1+.

## Development

```bash
bundle install
bundle exec rails app:db:create app:db:migrate RAILS_ENV=test
bundle exec rake test
```

Working against an unpushed sibling checkout of `rpms-rpc`:

```bash
bundle config local.rpms-rpc ../rpms-rpc
```

## Contributing

Each feature PR ports one BDD feature set from the legacy `rpms_redux`
codebase. The Cucumber scenarios are the spec; new code makes them
pass without rewriting the assertions.

See `docs/features.md` for the port roadmap and ADRs in `docs/adr/`
for the architectural decisions that shape the engine.

## License

MIT. See [MIT-LICENSE](MIT-LICENSE).
