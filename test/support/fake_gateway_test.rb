# frozen_string_literal: true

require "test_helper"

class SharedFakeGatewayTest < ActiveSupport::TestCase
  # --- Encounter shape: FakeGateway.new(:method_name, return_value) ---

  test "encounter shape defines a singleton method that returns a fixed value" do
    payload = { visit_ien: 1, status: "A" }
    fake = ::FakeGateway.new(:open, payload)

    assert_equal payload, fake.open
    assert_equal [ { args: [], kwargs: {} } ], fake.calls
  end

  test "encounter shape records each call as args and kwargs" do
    fake = ::FakeGateway.new(:for_patient, [])

    fake.for_patient(26664)
    fake.for_patient(1, 44, provider_duz: 99)

    assert_equal 2, fake.calls.length
    assert_equal({ args: [ 26664 ], kwargs: {} }, fake.calls[0])
    assert_equal({ args: [ 1, 44 ], kwargs: { provider_duz: 99 } }, fake.calls[1])
  end

  test "encounter shape invokes a proc return value with the same args and kwargs" do
    fake = ::FakeGateway.new(:brief_header, ->(*args, **kwargs) { { captured_args: args, captured_kwargs: kwargs } })

    result = fake.brief_header(8791, extra: true)

    assert_equal({ captured_args: [ 8791 ], captured_kwargs: { extra: true } }, result)
    assert_equal 1, fake.calls.length
  end

  test "encounter shape proc return can raise like the inline double" do
    fake = ::FakeGateway.new(:for_patient, ->(*) { raise "rpc timeout" })

    error = assert_raises(RuntimeError) { fake.for_patient(1) }
    assert_equal "rpc timeout", error.message
    assert_equal 1, fake.calls.length
  end

  test "encounter shape returns nil when configured with nil" do
    fake = ::FakeGateway.new(:open, nil)

    assert_nil fake.open(1, 2)
    assert_equal [ { args: [ 1, 2 ], kwargs: {} } ], fake.calls
  end

  # --- Vitals shape: FakeGateway.new(:add, return_value) ---

  test "vitals shape FakeGateway.new(:add, value) responds to #add and records calls" do
    response = { success: true }
    fake = ::FakeGateway.new(:add, response)

    assert_respond_to fake, :add
    assert_equal response, fake.add(8791, "visit", [], provider_duz: 1)
    assert_equal 1, fake.calls.length
    assert_equal({ args: [ 8791, "visit", [] ], kwargs: { provider_duz: 1 } }, fake.calls.first)
  end

  # --- with_stub: save and restore singleton methods ---

  test "with_stub replaces a singleton method for the block and restores the original" do
    host = stub_host_class

    with_stub(host, :gateway_method, :stubbed) do
      assert_equal :stubbed, host.gateway_method
    end

    assert_equal :original, host.gateway_method
  end

  test "with_stub restores the original singleton method when the block raises" do
    host = stub_host_class

    assert_raises(RuntimeError) do
      with_stub(host, :gateway_method, :stubbed) do
        assert_equal :stubbed, host.gateway_method
        raise "boom"
      end
    end

    assert_equal :original, host.gateway_method
  end

  test "with_stub on an undefined singleton method removes the stub afterward" do
    host = Class.new
    refute host.singleton_class.method_defined?(:not_yet)

    with_stub(host, :not_yet, 42) do
      assert_equal 42, host.not_yet
      assert host.singleton_class.method_defined?(:not_yet)
    end

    refute host.singleton_class.method_defined?(:not_yet)
  end

  test "with_stub stub ignores call arguments and returns the configured value" do
    host = stub_host_class

    with_stub(host, :gateway_method, { ok: true }) do
      assert_equal({ ok: true }, host.gateway_method(1, 2, extra: 3))
    end
  end

  private

  def stub_host_class
    klass = Class.new
    klass.define_singleton_method(:gateway_method) { |*_args, **_kwargs| :original }
    klass
  end
end
