# frozen_string_literal: true

# One method, every call recorded as { args:, kwargs: }. A Proc return value
# is invoked with those same arguments; any other value is returned as-is.
# The call is recorded before the proc runs, so a raise still leaves a trace.
class FakeGateway
  attr_reader :calls

  def initialize(method_name, return_value)
    @return_value = return_value
    @calls = []
    define_singleton_method(method_name) { |*args, **kwargs| record_call(args, kwargs) }
  end

  private

  def record_call(args, kwargs)
    @calls << { args: args, kwargs: kwargs }
    return @return_value.call(*args, **kwargs) if @return_value.respond_to?(:call)

    @return_value
  end
end
