# frozen_string_literal: true

require "test_helper"

# Contract for LiveStack (test/support/live_stack.rb), the harness behind
# `cucumber --profile stack` (#962).
#
# A @live run takes its whole binding from five environment variables, signs on
# as one persona who must not hold XUPROGMODE, and fails closed: anything it
# cannot confirm makes the run "not run", never passed. Every code here is
# synthetic.
class LiveStackTest < ActiveSupport::TestCase
  ACCESS = "SYNTH1"
  VERIFY = "SYNTH1!!"
  Result = Lakeraven::EHR::AuthenticationService::Result
  CONTEXT_REFUSED = Lakeraven::EHR::AuthenticationService::CONTEXT_REFUSED

  def full_env(overrides = {})
    {
      "RPMS_IP" => "192.0.2.10", "RPMS_PORT" => "9100", "RPMS_BROKER" => "cia",
      "RPMS_ACCESS" => ACCESS, "RPMS_VERIFY" => VERIFY
    }.merge(overrides)
  end

  # Runs LiveStack.prepare with recording collaborators. Returns [status, calls]
  # where calls is the ordered list of [collaborator, *arguments].
  def prepare(env, connect: nil, authenticate: nil, held_keys: nil)
    calls = []
    signed_on = Result.new(success?: true, value: { duz: 1 }, error: nil)
    connect ||= ->(_binding) { }
    authenticate ||= ->(_access, _verify) { signed_on }
    held_keys ||= ->(_names) { [] }
    status = LiveStack.prepare(
      env,
      connect: ->(binding) { calls << [ :connect, binding ]; connect.call(binding) },
      authenticate: ->(access, verify) { calls << [ :authenticate, access, verify ]; authenticate.call(access, verify) },
      held_keys: ->(names) { calls << [ :held_keys, names ]; held_keys.call(names) }
    )
    [ status, calls ]
  end

  def called(calls) = calls.map(&:first)

  def assert_no_codes(text)
    assert_not_includes text.to_s, VERIFY, "the verify code leaked"
    assert_not_includes text.to_s, ACCESS, "the access code leaked"
  end

  def assert_not_ready(status)
    assert_not status.ready?, "expected the stack not to be ready"
    assert_kind_of String, status.reason
    assert_not_empty status.reason
    assert_no_codes status.reason
  end

  # -- the binding ----------------------------------------------------------

  test "the binding is exactly five variables" do
    assert_equal %w[RPMS_IP RPMS_PORT RPMS_BROKER RPMS_ACCESS RPMS_VERIFY], LiveStack::VARIABLES
  end

  test "a stack run is not requested without LIVE_STACK" do
    assert_equal false, LiveStack.requested?({})
    assert_equal false, LiveStack.requested?(full_env)
  end

  test "a stack run is requested only by LIVE_STACK=1" do
    assert_equal true, LiveStack.requested?({ "LIVE_STACK" => "1" })
    assert_equal false, LiveStack.requested?({ "LIVE_STACK" => "0" })
    assert_equal false, LiveStack.requested?({ "LIVE_STACK" => "true" })
    assert_equal false, LiveStack.requested?({ "LIVE_STACK" => "" })
  end

  test "an empty environment is missing every variable, in order" do
    assert_equal LiveStack::VARIABLES, LiveStack.missing({})
  end

  test "a full environment is missing nothing" do
    assert_equal [], LiveStack.missing(full_env)
    assert_equal [], LiveStack.missing(full_env("RPMS_BROKER" => "xwb"))
  end

  test "an unset variable is missing" do
    LiveStack::VARIABLES.each do |name|
      assert_equal [ name ], LiveStack.missing(full_env.except(name)), "#{name} unset"
    end
  end

  test "a blank variable is missing" do
    LiveStack::VARIABLES.each do |name|
      assert_equal [ name ], LiveStack.missing(full_env(name => "")), "#{name} empty"
      assert_equal [ name ], LiveStack.missing(full_env(name => "  ")), "#{name} whitespace"
    end
  end

  test "missing variables are listed in VARIABLES order" do
    env = full_env.except("RPMS_VERIFY", "RPMS_IP", "RPMS_BROKER")
    assert_equal %w[RPMS_IP RPMS_BROKER RPMS_VERIFY], LiveStack.missing(env)
  end

  test "a port that is not an integer from 1 to 65535 is missing" do
    %w[abc 70000 0 -1 65536 91.5 9100x].each do |port|
      assert_equal [ "RPMS_PORT" ], LiveStack.missing(full_env("RPMS_PORT" => port)), "port #{port.inspect}"
    end
    %w[1 9100 65535].each do |port|
      assert_equal [], LiveStack.missing(full_env("RPMS_PORT" => port)), "port #{port.inspect}"
    end
  end

  test "a broker that is neither cia nor xwb is missing" do
    %w[bmx CIA mock].each do |broker|
      assert_equal [ "RPMS_BROKER" ], LiveStack.missing(full_env("RPMS_BROKER" => broker)), "broker #{broker.inspect}"
    end
  end

  test "missing answers with names only, never values" do
    missing = LiveStack.missing(full_env("RPMS_PORT" => "abc", "RPMS_BROKER" => "bmx"))
    assert_equal %w[RPMS_PORT RPMS_BROKER], missing
  end

  test "there is no binding while anything is missing" do
    assert_nil LiveStack.binding({})
    assert_nil LiveStack.binding(full_env.except("RPMS_VERIFY"))
    assert_nil LiveStack.binding(full_env("RPMS_PORT" => "70000"))
    assert_nil LiveStack.binding(full_env("RPMS_BROKER" => "bmx"))
  end

  test "a full environment binds the stack and the persona" do
    binding = LiveStack.binding(full_env)

    assert_kind_of LiveStack::Binding, binding
    assert_equal "192.0.2.10", binding.host
    assert_equal 9100, binding.port
    assert_equal "cia", binding.broker
    assert_equal ACCESS, binding.access_code
    assert_equal VERIFY, binding.verify_code
  end

  test "the binding needs nothing but its five variables" do
    env = full_env("VISTA_RPC_HOST" => "198.51.100.1", "LIVE_RPMS_ACCESS" => "OTHER", "LIVE_RPMS_VERIFY" => "OTHER!!")
    binding = LiveStack.binding(env)

    assert_equal "192.0.2.10", binding.host
    assert_equal ACCESS, binding.access_code
    assert_equal VERIFY, binding.verify_code
  end

  test "a binding never shows its codes" do
    binding = LiveStack.binding(full_env)

    assert_no_codes binding.inspect
    assert_no_codes binding.to_s
    assert_no_codes "#{binding}"
  end

  # -- prepare: fail closed -------------------------------------------------

  test "a missing binding is not ready and touches nothing" do
    status, calls = prepare({})

    assert_not_ready status
    LiveStack::VARIABLES.each { |name| assert_includes status.reason, name }
    assert_empty calls, "nothing may be called without a binding"
  end

  test "a partly missing binding names each missing variable and touches nothing" do
    status, calls = prepare(full_env("RPMS_PORT" => "abc").except("RPMS_IP"))

    assert_not_ready status
    assert_includes status.reason, "RPMS_IP"
    assert_includes status.reason, "RPMS_PORT"
    assert_not_includes status.reason, "RPMS_BROKER"
    assert_not_includes status.reason, "RPMS_VERIFY"
    assert_empty calls
  end

  test "an unreachable broker is not ready and no sign-on is attempted" do
    status, calls = prepare(full_env, connect: ->(_b) { raise RpmsRpc::Client::ConnectionError, "connection refused" })

    assert_not_ready status
    assert_equal [ :connect ], called(calls)
  end

  test "connect is given the binding" do
    _status, calls = prepare(full_env)
    binding = calls.assoc(:connect).last

    assert_kind_of LiveStack::Binding, binding
    assert_equal "192.0.2.10", binding.host
    assert_equal 9100, binding.port
    assert_equal "cia", binding.broker
  end

  test "a refused context is not run" do
    refused = Result.new(success?: false, value: nil, error: CONTEXT_REFUSED)
    status, calls = prepare(full_env, authenticate: ->(_a, _v) { refused })

    assert_not_ready status
    assert_includes status.reason, "context refused"
    assert_not_includes called(calls), :held_keys

    message = LiveStack.not_run_message(status)
    assert message.start_with?("not run:"), "expected #{message.inspect} to start with 'not run:'"
    assert_includes message, "context refused"
    assert_no_codes message
  end

  test "a refused sign-on is not ready" do
    refused = Result.new(success?: false, value: nil, error: "Invalid credentials")
    status, calls = prepare(full_env, authenticate: ->(_a, _v) { refused })

    assert_not_ready status
    assert_includes status.reason, "sign-on refused"
    assert_not_includes status.reason, "context refused"
    assert_not_includes called(calls), :held_keys
  end

  test "a refused sign-on whose error repeats the codes still leaks neither" do
    refused = Result.new(success?: false, value: nil, error: "refused #{ACCESS};#{VERIFY}")
    status, _calls = prepare(full_env, authenticate: ->(_a, _v) { refused })

    assert_not_ready status
    assert_includes status.reason, "sign-on refused"
  end

  test "not being able to ask about XUPROGMODE is not ready" do
    status, calls = prepare(full_env, held_keys: ->(_names) { nil })

    assert_not_ready status
    assert_includes status.reason, "XUPROGMODE"
    assert_equal [ :held_keys, [ "XUPROGMODE" ] ], calls.last
  end

  test "a persona holding XUPROGMODE is not ready" do
    status, _calls = prepare(full_env, held_keys: ->(_names) { [ "XUPROGMODE" ] })

    assert_not_ready status
    assert_includes status.reason, "XUPROGMODE"
  end

  test "a persona without XUPROGMODE on a reachable stack is ready" do
    status, calls = prepare(full_env)

    assert status.ready?, "expected ready, got: #{status.reason}"
    assert_nil status.reason
    assert_equal %i[connect authenticate held_keys], called(calls)
    assert_equal [ :authenticate, ACCESS, VERIFY ], calls.assoc(:authenticate)
    assert_equal [ :held_keys, [ "XUPROGMODE" ] ], calls.assoc(:held_keys)
  end

  test "not_run_message is the reason behind 'not run:'" do
    status, _calls = prepare({})

    assert_equal "not run: #{status.reason}", LiveStack.not_run_message(status)
  end

  # -- refusals in the middle of a scenario ---------------------------------

  # A broker client whose call_rpc raises what the test asks, or answers.
  def watched_client(raises: nil)
    Class.new do
      prepend LiveStack::RefusalWatch

      define_method(:call_rpc) do |rpc_name, *params|
        raise raises if raises

        [ rpc_name, *params ]
      end
    end.new
  end

  test "a refused RPC is recorded by name and still raised" do
    LiveStack.take_refusals
    error = RpmsRpc::Client::RpcRefusedError.new("not in this context")
    client = watched_client(raises: error)

    raised = assert_raises(RpmsRpc::Client::RpcRefusedError) { client.call_rpc("ORWPT LIST ALL", "A", 1) }

    assert_same error, raised
    assert_equal [ "ORWPT LIST ALL" ], LiveStack.take_refusals
  end

  test "taking the refusals clears them" do
    LiveStack.take_refusals
    client = watched_client(raises: RpmsRpc::Client::RpcRefusedError.new("refused"))
    assert_raises(RpmsRpc::Client::RpcRefusedError) { client.call_rpc("ORWU USERINFO") }
    assert_raises(RpmsRpc::Client::RpcRefusedError) { client.call_rpc("ORQQAL LIST", 4) }

    assert_equal [ "ORWU USERINFO", "ORQQAL LIST" ], LiveStack.take_refusals
    assert_equal [], LiveStack.take_refusals
  end

  test "an answered RPC passes through and records nothing" do
    LiveStack.take_refusals

    assert_equal [ "ORWU USERINFO", "x" ], watched_client.call_rpc("ORWU USERINFO", "x")
    assert_equal [], LiveStack.take_refusals
  end

  test "other broker errors are raised and not recorded as refusals" do
    LiveStack.take_refusals
    [ RpmsRpc::Client::ConnectionError, RpmsRpc::Client::RpcNotAvailableError, RpmsRpc::Client::RpcMError ].each do |klass|
      client = watched_client(raises: klass.new("boom"))
      assert_raises(klass) { client.call_rpc("ORWU USERINFO") }
    end

    assert_equal [], LiveStack.take_refusals
  end
end
