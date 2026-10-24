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
