# Test helpers

`test/test_helper.rb` loads the helpers in this directory. Service tests that
inject a gateway, and Cucumber steps that swap a gateway singleton method,
share the two below.

## FakeGateway

`FakeGateway.new(method_name, return_value)` defines `method_name` on the
double, appends `{ args:, kwargs: }` to `calls` for every invocation, and
returns `return_value`. When `return_value` is a Proc, the double calls it
with the same arguments and returns that result. The call is recorded before
the proc runs, so a raise still leaves an entry in `calls`.

```ruby
fake = FakeGateway.new(:for_patient, [])
fake.for_patient(26664, provider_duz: 99)
fake.calls # => [ { args: [ 26664 ], kwargs: { provider_duz: 99 } } ]

FakeGateway.new(:for_patient, ->(*) { raise "rpc timeout" })
```

`EncounterLifecycleService` tests pass the method each gateway is asked for
(`:open`, `:brief_header`, `:for_patient`, `:applicable`). `VitalsEntryService`
tests pass `:add`:

```ruby
gateway = FakeGateway.new(:add, { success: true })
```

Pass the double through the service constructor so the production gateway
class keeps its own methods.

## with_stub

`with_stub(klass, method_name, value) { ... }` replaces `klass`'s singleton
`method_name` for the block. The stub ignores its arguments and returns
`value`. An `ensure` puts the previous singleton method back, including when
the block raises. When `klass` did not already define that singleton method,
the stub is removed when the block ends and an inherited method stays where
it was.

```ruby
with_stub(Lakeraven::EHR::PatientGateway, :brief_header, { name: "TEST" }) do
  Lakeraven::EHR::PatientGateway.brief_header(1) # => { name: "TEST" }
end
```

Cucumber scenarios install stubs during steps and restore them after the
scenario. `features/support/gateway_stubs.rb` keeps `stub_gateway` for step
definitions and delegates to `StubHelpers.install_singleton_stub`, the same
save-and-restore `with_stub` uses. `part2` steps that push their own restore
procs onto `@gateway_stubs` still run from the `After` hook.

## Per-checkout test database

Each checkout gets its own test database, so two worktrees can run the suite
at the same time. `test/dummy/config/database.yml` asks
`Lakeraven::EHR::TestDatabaseName` for the name.

A primary checkout (`.git` is a directory) and a tree with no `.git` use
`lakeraven_ehr_test`. Any checkout whose `.git` is a file (a linked worktree
or a git submodule) gets a hashed name: `lakeraven_ehr_test_` plus the first
8 hex digits of the SHA-256 of the checkout's real path.

Set `TEST_DATABASE` to choose the name yourself. A blank value is ignored.
The name has to match `[a-z][a-z0-9_]*` and be at most 63 bytes;
otherwise loading the config raises `ArgumentError` naming `TEST_DATABASE`.
A blank `TEST_ENV_NUMBER` is ignored. Digits are appended as `_<n>`. Any
other value raises `ArgumentError` naming `TEST_ENV_NUMBER`.

CI sets `DATABASE_URL`. Rails uses that URL in place of the name above.

Create the database and load `schema.rb` for this checkout:

```bash
$ RAILS_ENV=test bin/rails db:create db:schema:load
```

Moving a worktree changes its database name, because the hash is of the real
path. Run `db:create` and `db:schema:load` again for the new path, and drop
the old database.

List stale per-worktree databases — checkout `lakeraven_ehr_test_*` and red-before-green `lakeraven_ehr_rbg_*` — with `psql -l | grep lakeraven_ehr_`.
Drop one with `dropdb <name>`, or from that worktree:

```bash
$ RAILS_ENV=test bin/rails db:drop
```

Locally, `bin/red-before-green` makes and drops its own scratch database
(named `lakeraven_ehr_rbg_<suffix>`) when `DATABASE_URL` is unset. A cancelled
or killed red-before-green run can leave a stale `lakeraven_ehr_rbg_*` database
behind; the listing above finds it. CI sets `DATABASE_URL`, so the script does
not create or drop a database there.
