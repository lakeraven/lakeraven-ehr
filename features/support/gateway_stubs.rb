# frozen_string_literal: true

require_relative "../../test/support/stub_helpers"

# Per-scenario gateway stubbing. install_singleton_stub is the same
# save-and-restore with_stub uses, so a production singleton method is put
# back after the scenario, including when a step overwrites the stub or the
# scenario fails. Step definitions, and part2 steps that push their own
# restore procs, share @gateway_stubs.

Before do
  @gateway_stubs = []
end

After do
  @gateway_stubs.reverse_each(&:call) if @gateway_stubs
  @gateway_stubs = nil
end

def stub_gateway(klass, method_name, return_value)
  @gateway_stubs << StubHelpers.install_singleton_stub(klass, method_name, return_value)
end
