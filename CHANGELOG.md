# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial Rails 8.1 mountable engine scaffold
- `Lakeraven::EHR` module namespace (capitalized acronym, not the
  generator default `Lakeraven::Ehr`)
- Gemspec metadata, MIT license, and runtime dependency on
  `rpms-rpc ~> 0.1`
- `Gemfile` git source pin to `rpms-rpc` v0.1.0 until it lands on
  rubygems.org
- `rake test` alias to `rake app:test` so the engine matches the
  invocation convention used in `rpms-rpc` and the rest of the
  Lakeraven Ruby repos
- `rubocop-rails-omakase` configuration
- GitHub Actions CI: Ruby 3.4 + postgres:16, runs the dummy app's
  test database migrations and the test suite, plus a separate
  rubocop lint job
- README documenting scope, what is and isn't in the engine, and
  the architectural relationship to `rpms-rpc`, `corvid`, and the
  private host app

### Notes

This is the bootstrap. Feature work begins in the next batch:

- patient_search
- provider_search
- US Core Patient API
- FHIR/SMART authentication
- SMART EHR launch
- PHI audit logging
