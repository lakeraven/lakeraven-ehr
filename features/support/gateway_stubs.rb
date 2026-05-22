# frozen_string_literal: true

# Per-scenario gateway stubbing — replaces a Class.singleton_method with a
# fixed return value for the duration of one scenario, then restores. Prevents
# the "removed production method bleeds into later scenarios" failure mode.

Before do
  @gateway_stubs = []
end

After do
  @gateway_stubs.reverse_each(&:call) if @gateway_stubs
  @gateway_stubs = nil
end

def stub_gateway(klass, method_name, return_value)
  sc = klass.singleton_class
  if sc.method_defined?(method_name) && sc.instance_method(method_name).owner == sc
    original = sc.instance_method(method_name)
    @gateway_stubs << -> { sc.send(:define_method, method_name, original) }
  else
    @gateway_stubs << -> { sc.send(:remove_method, method_name) if sc.method_defined?(method_name) }
  end
  klass.define_singleton_method(method_name) { |*_a, **_kw| return_value }
end
