# frozen_string_literal: true

require "test_helper"
require "pp"
require "json"
require "yaml"
require "cucumber/core/test/result"

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

  # -- prepare: amendment 1 -------------------------------------------------

  test "an unexpected error from any collaborator is not ready and its message is not repeated" do
    boom = -> { raise "exploded with #{ACCESS};#{VERIFY}" }
    {
      connect: { connect: ->(_b) { boom.call } },
      authenticate: { authenticate: ->(_a, _v) { boom.call } },
      held_keys: { held_keys: ->(_names) { boom.call } }
    }.each do |name, collaborator|
      status, _calls = prepare(full_env, **collaborator)

      assert_not_ready status
      assert_not_includes status.reason, "exploded", "#{name}: the error's message reached the reason"
    end
  end

  test "RPMS_UCI in the environment is not ready, is named, and touches nothing" do
    status, calls = prepare(full_env("RPMS_UCI" => "EHR"))

    assert_not_ready status
    assert_includes status.reason, "RPMS_UCI"
    assert_empty calls, "nothing may be called when the environment carries more than the binding"
  end

  test "a client installed before a not-ready outcome is disconnected and the previous client restored" do
    before = RpmsRpc.configuration.client
    fake = Class.new do
      attr_reader :disconnects

      def initialize = @disconnects = 0
      def disconnect = @disconnects += 1
    end.new

    begin
      status, _calls = prepare(
        full_env,
        connect: ->(_b) { RpmsRpc.configure { |c| c.client = fake } },
        held_keys: ->(_names) { [ "XUPROGMODE" ] }
      )

      assert_not_ready status
      assert_operator fake.disconnects, :>=, 1, "the installed client was not disconnected"
      assert_same before, RpmsRpc.configuration.client, "the client from before prepare was not restored"
    ensure
      RpmsRpc.configure { |c| c.client = before }
    end
  end

  test "a ready status exposes the persona's DUZ as a String" do
    signed_on = Result.new(success?: true, value: { duz: 4321 }, error: nil)
    status, _calls = prepare(full_env, authenticate: ->(_a, _v) { signed_on })

    assert status.ready?, "expected ready, got: #{status.reason}"
    assert_equal "4321", status.persona_duz
  end

  # -- the binding keeps its codes to itself --------------------------------

  test "a binding reveals its codes only through access_code and verify_code" do
    binding = LiveStack.binding(full_env)

    assert_equal ACCESS, binding.access_code
    assert_equal VERIFY, binding.verify_code
    assert_no_codes binding.inspect
    assert_no_codes binding.to_s
    assert_no_codes binding.pretty_inspect
    assert_not binding.respond_to?(:to_h), "to_h would hand out the codes"
    assert_not binding.respond_to?(:to_a), "to_a would hand out the codes"
    assert_not binding.respond_to?(:deconstruct), "deconstruct would hand out the codes"
    assert_not_kind_of Struct, binding
  end

  # -- the binding never serialises its codes (amendment 2) ------------------

  test "a binding never serialises its codes" do
    binding = LiveStack.binding(full_env)

    assert_no_codes binding.to_json
    assert_no_codes binding.as_json.to_s
    assert_no_codes binding.to_yaml
    assert_no_codes JSON.generate(binding)
    assert_no_codes YAML.dump(binding)
  end

  # -- evidence: what a scenario did against the stack ----------------------

  WATCHED = %i[call_rpc call_rpc_raw call_rpc_global_array create_context authenticate].freeze
  RPC_METHODS = %i[call_rpc call_rpc_raw call_rpc_global_array].freeze
  # The parsed calls: the only ones whose answer can be evidence. A raw reply
  # is unparsed, so a refusal can arrive in it as data.
  COUNTED = %i[call_rpc call_rpc_global_array].freeze
  Client = RpmsRpc::Client
  PERSONA_DUZ = "4321"

  # Evidence and arming are process-wide: every test starts and ends unarmed
  # with nothing recorded. (Guarded only so that the tests which do not arm
  # report their own result while disarm! does not exist yet; "disarming
  # fails closed again" pins disarm! itself.)
  setup do
    LiveStack.disarm! if LiveStack.respond_to?(:disarm!)
    LiveStack.take_evidence
  end

  teardown do
    LiveStack.disarm! if LiveStack.respond_to?(:disarm!)
    LiveStack.take_evidence
  end

  # A broker client whose four watched methods raise what the test asks, or
  # answer with their arguments. It is signed on as `duz`; both can be changed
  # between calls.
  def watched_client(raises: nil, duz: PERSONA_DUZ)
    Class.new do
      prepend LiveStack::RefusalWatch

      attr_accessor :duz, :raises

      define_method(:initialize) do
        @raises = raises
        @duz = duz
      end

      RPC_METHODS.each do |name|
        define_method(name) do |rpc_name, *params|
          raise @raises if @raises

          [ rpc_name, *params ]
        end
      end

      define_method(:create_context) do |option_name = "OR CPRS GUI CHART"|
        raise @raises if @raises

        option_name
      end
    end.new
  end

  # The persona's own client: a watched client signed on as the persona, and
  # the one the watch is armed with.
  def armed_client(raises: nil, duz: PERSONA_DUZ, persona_duz: PERSONA_DUZ)
    watched_client(raises: raises, duz: duz).tap do |client|
      LiveStack.arm!(client: client, persona_duz: persona_duz)
    end
  end

  def assert_not_run(error, naming:)
    assert_kind_of Cucumber::Core::Test::Result::Skipped, error
    assert error.message.start_with?("not run:"), "expected #{error.message.inspect} to start with 'not run:'"
    assert_includes error.message, naming
    assert_no_codes error.message
  end

  def assert_nothing_counted(evidence, context = nil)
    assert_equal 0, evidence.rpc_count, [ context, "counted as a stack RPC" ].compact.join(": ")
  end

  test "NotRun is a cucumber skip" do
    assert_operator LiveStack::NotRun, :<, Cucumber::Core::Test::Result::Skipped
  end

  test "evidence starts empty once taken" do
    LiveStack.take_evidence
    evidence = LiveStack.take_evidence

    assert_equal 0, evidence.rpc_count
    assert_equal [], evidence.reasons
  end

  test "every answered parsed call by the persona on the armed client counts as a stack RPC and records no reason" do
    COUNTED.each do |name|
      LiveStack.take_evidence
      client = armed_client

      assert_equal [ "ORWU USERINFO", "x" ], client.public_send(name, "ORWU USERINFO", "x"), name.to_s
      assert_operator LiveStack.rpc_count, :>=, 1, "#{name} was not counted"

      evidence = LiveStack.take_evidence
      assert_kind_of Integer, evidence.rpc_count
      assert_operator evidence.rpc_count, :>=, 1, "#{name} was not counted"
      assert_equal [], evidence.reasons
    end
  end

  test "the armed client's DUZ is compared as text with the persona's" do
    client = armed_client(duz: 4321, persona_duz: "4321")

    client.call_rpc("ORWU USERINFO")

    evidence = LiveStack.take_evidence
    assert_operator evidence.rpc_count, :>=, 1
    assert_equal [], evidence.reasons
  end

  test "a call counts only once it has returned" do
    seen = nil
    client = Class.new do
      prepend LiveStack::RefusalWatch

      attr_reader :duz

      define_method(:initialize) { @duz = PERSONA_DUZ }
      define_method(:call_rpc) do |rpc_name, *_params|
        seen = LiveStack.rpc_count
        rpc_name
      end
    end.new
    LiveStack.arm!(client: client, persona_duz: PERSONA_DUZ)

    client.call_rpc("ORWU USERINFO")

    assert_equal 0, seen, "the call was counted before it returned"
    assert_operator LiveStack.rpc_count, :>=, 1
  end

  test "an answered call when nothing is armed counts nothing and says so" do
    COUNTED.each do |name|
      LiveStack.take_evidence

      assert_equal [ "ORWU USERINFO", "x" ], watched_client.public_send(name, "ORWU USERINFO", "x"), name.to_s

      assert_equal 0, LiveStack.rpc_count, "#{name} was counted with nothing armed"
      evidence = LiveStack.take_evidence
      assert_nothing_counted evidence, name
      assert_equal 1, evidence.reasons.size, name.to_s
      assert_includes evidence.reasons.first, "not armed"
      assert_no_codes evidence.reasons.first
    end
  end

  test "an answered call on any other object counts nothing, however alike the object" do
    COUNTED.each do |name|
      LiveStack.take_evidence
      armed_client
      twin = watched_client

      assert_equal [ "ORWU USERINFO", "x" ], twin.public_send(name, "ORWU USERINFO", "x"), name.to_s

      evidence = LiveStack.take_evidence
      assert_nothing_counted evidence, name
      assert_equal 1, evidence.reasons.size, name.to_s
      assert_includes evidence.reasons.first, "not the persona's client"
      assert_no_codes evidence.reasons.first
    end
  end

  test "an answered call on the armed client signed on as someone else, or as no one, counts nothing" do
    [ "1", 1, nil, "" ].each do |duz|
      COUNTED.each do |name|
        LiveStack.take_evidence
        client = armed_client(duz: duz)

        client.public_send(name, "ORWU USERINFO")

        evidence = LiveStack.take_evidence
        assert_nothing_counted evidence, "#{name} as DUZ #{duz.inspect}"
        assert_equal 1, evidence.reasons.size, "#{name} as DUZ #{duz.inspect}"
        assert_includes evidence.reasons.first, "not the persona's client"
      end
    end
  end

  test "the DUZ is read at call time, not when the watch is armed" do
    client = armed_client

    client.call_rpc("ORWU USERINFO")
    assert_operator LiveStack.take_evidence.rpc_count, :>=, 1, "the persona's own call was not counted"

    client.duz = "1"
    client.call_rpc("ORWU USERINFO")
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "after signing on as someone else"
    assert_equal 1, evidence.reasons.size
    assert_includes evidence.reasons.first, "not the persona's client"

    client.duz = PERSONA_DUZ
    client.call_rpc("ORWU USERINFO")
    evidence = LiveStack.take_evidence
    assert_operator evidence.rpc_count, :>=, 1, "the persona's call after signing back on was not counted"
    assert_equal [], evidence.reasons
  end

  test "arming again binds the evidence to the new client alone" do
    first = armed_client
    second = armed_client

    first.call_rpc("ORWU USERINFO")
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "the client armed before"
    assert_includes evidence.reasons.first.to_s, "not the persona's client"

    second.call_rpc("ORWU USERINFO")
    evidence = LiveStack.take_evidence
    assert_operator evidence.rpc_count, :>=, 1
    assert_equal [], evidence.reasons
  end

  test "disarming fails closed again" do
    client = armed_client
    LiveStack.disarm!

    client.call_rpc("ORWU USERINFO")

    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "after disarm!"
    assert_equal 1, evidence.reasons.size
    assert_includes evidence.reasons.first, "not armed"
  end

  test "an answered create_context never counts and records no reason" do
    assert_equal "OR CPRS GUI CHART", armed_client.create_context("OR CPRS GUI CHART")

    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "create_context on the armed client"
    assert_equal [], evidence.reasons

    LiveStack.disarm!
    assert_equal "OR CPRS GUI CHART", watched_client.create_context("OR CPRS GUI CHART")

    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "create_context with nothing armed"
    assert_equal [], evidence.reasons
  end

  test "taking the evidence clears the count and the reasons" do
    client = armed_client
    client.call_rpc("ORWU USERINFO")
    client.call_rpc("ORQQAL LIST", 4)
    client.raises = Client::RpcRefusedError.new("refused")
    assert_raises(LiveStack::NotRun) { client.call_rpc("ORWU USERINFO") }
    assert_raises(LiveStack::NotRun) { client.call_rpc("ORQQAL LIST", 4) }

    evidence = LiveStack.take_evidence
    assert_operator evidence.rpc_count, :>=, 2
    assert_equal 2, evidence.reasons.size
    assert_includes evidence.reasons.first, "ORWU USERINFO"
    assert_includes evidence.reasons.last, "ORQQAL LIST"

    again = LiveStack.take_evidence
    assert_equal 0, again.rpc_count
    assert_equal [], again.reasons
    assert_equal 0, LiveStack.rpc_count
  end

  # Every broker error but RpcMError: the four the watch already declined,
  # their subclasses, and the ones round 2 found passing through.
  DECLINED = [
    Client::RpcRefusedError, Client::RpcNotAvailableError, Client::ConnectionError,
    Client::RpcTimeoutError, Client::AuthenticationError, Client::ContextRefusedError,
    Client::RpcError, Client::ParseError, Client::FrameTooLongError, RpmsRpc::Error
  ].freeze

  test "any broker error but a routine that ran and failed is not run, on every watched RPC method" do
    DECLINED.each do |klass|
      RPC_METHODS.each do |name|
        LiveStack.take_evidence
        client = armed_client(raises: klass.new("broker said #{ACCESS};#{VERIFY}"))

        error = assert_raises(LiveStack::NotRun, "#{klass} from #{name}") { client.public_send(name, "ORWPT LIST ALL", "A", 1) }
        assert_not_run error, naming: "ORWPT LIST ALL"
        assert_nil error.cause, "#{klass} from #{name}: the broker's error travelled with the skip"
        assert_not_includes error.message, "broker said", "#{klass} from #{name}: the broker's message was repeated"

        evidence = LiveStack.take_evidence
        assert_nothing_counted evidence, "#{klass} raised from #{name}"
        assert_equal 1, evidence.reasons.size, "#{klass} from #{name}"
        assert_kind_of String, evidence.reasons.first
        assert_includes evidence.reasons.first, "ORWPT LIST ALL"
        assert_not_includes evidence.reasons.first, "broker said"
        assert_no_codes evidence.reasons.first
      end
    end
  end

  test "a broker error is not run whoever made the call" do
    [ Client::RpcRefusedError, Client::ParseError ].each do |klass|
      LiveStack.take_evidence
      error = assert_raises(LiveStack::NotRun, "#{klass}, nothing armed") do
        watched_client(raises: klass.new("broker said #{ACCESS};#{VERIFY}")).call_rpc("ORWPT LIST ALL")
      end
      assert_not_run error, naming: "ORWPT LIST ALL"

      evidence = LiveStack.take_evidence
      assert_nothing_counted evidence, "#{klass} with nothing armed"
      assert_equal 1, evidence.reasons.size, "#{klass}, nothing armed"
      assert_includes evidence.reasons.first, "ORWPT LIST ALL"
    end
  end

  test "any broker error from create_context is not run and names the context option" do
    [
      RpmsRpc::Error, Client::ContextRefusedError, Client::RpcRefusedError, Client::ConnectionError,
      Client::RpcMError, Client::ParseError
    ].each do |klass|
      LiveStack.take_evidence
      client = armed_client(raises: klass.new("broker said #{ACCESS};#{VERIFY}"))

      error = assert_raises(LiveStack::NotRun, klass.to_s) { client.create_context("OR CPRS GUI CHART") }
      assert_not_run error, naming: "OR CPRS GUI CHART"

      evidence = LiveStack.take_evidence
      assert_nothing_counted evidence, "#{klass} raised from create_context"
      assert_equal 1, evidence.reasons.size, klass.to_s
      assert_includes evidence.reasons.first, "OR CPRS GUI CHART"
      assert_no_codes evidence.reasons.first
    end
  end

  # An M error is not evidence: the step still fails on the original error,
  # and a scenario that swallows it is not run.
  test "a routine that ran and failed is raised unchanged, does not count, and records an M error naming the RPC" do
    RPC_METHODS.each do |name|
      LiveStack.take_evidence
      failure = Client::RpcMError.new("<UNDEFINED>X+1^ORWU #{ACCESS};#{VERIFY}")
      client = armed_client(raises: failure)

      raised = assert_raises(Client::RpcMError, name.to_s) { client.public_send(name, "ORWU USERINFO") }

      assert_same failure, raised, "#{name}: the M error must stay the original object, not a skip"
      evidence = LiveStack.take_evidence
      assert_nothing_counted evidence, "#{name} raised"
      assert_equal 1, evidence.reasons.size, name.to_s
      assert_includes evidence.reasons.first, "ORWU USERINFO", name.to_s
      assert_includes evidence.reasons.first, "M error", name.to_s
      assert_not_includes evidence.reasons.first, "UNDEFINED", "#{name}: the broker's message was repeated"
      assert_no_codes evidence.reasons.first
    end
  end

  test "an M error is recorded whoever made the call" do
    failure = Client::RpcMError.new("<UNDEFINED>X+1^ORWU")

    raised = assert_raises(Client::RpcMError) { watched_client(raises: failure).call_rpc("ORWU USERINFO") }

    assert_same failure, raised
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "nothing armed"
    assert_equal 1, evidence.reasons.size
    assert_includes evidence.reasons.first, "M error"
  end

  test "a swallowed M error makes the verdict not run, whatever else was read" do
    client = armed_client
    client.call_rpc("ORWU USERINFO")
    client.raises = Client::RpcMError.new("<UNDEFINED>X+1^ORQQAL")
    begin
      client.call_rpc("ORQQAL LIST", 4)
    rescue Client::RpcMError
      nil
    end
    client.raises = nil
    client.call_rpc("ORWU USERINFO")

    reason = LiveStack.verdict(evidence: LiveStack.take_evidence, client: client, stack_client: client,
                               persona_duz: PERSONA_DUZ)

    assert_kind_of String, reason, "a scenario that swallowed an M error was reported as run"
    assert_includes reason, "ORQQAL LIST"
    assert_includes reason, "M error"
  end

  test "errors that are not broker errors pass through every watched method unchanged" do
    RPC_METHODS.each do |name|
      LiveStack.take_evidence
      failure = ArgumentError.new("wrong argument")
      raised = assert_raises(ArgumentError, name.to_s) { armed_client(raises: failure).public_send(name, "ORWU USERINFO") }

      assert_same failure, raised
      evidence = LiveStack.take_evidence
      assert_equal [], evidence.reasons
      assert_nothing_counted evidence, "#{name} raised"
    end

    LiveStack.take_evidence
    failure = ArgumentError.new("wrong argument")
    raised = assert_raises(ArgumentError) { armed_client(raises: failure).create_context("OR CPRS GUI CHART") }

    assert_same failure, raised
    assert_equal [], LiveStack.take_evidence.reasons
  end

  # -- nesting: only the outermost watched frame decides --------------------

  # A broker client whose watched methods call one another the way the real
  # ones do: call_rpc reads its raw reply through call_rpc_raw and parses it
  # afterwards (CIA raises the broker's error there), create_context sends its
  # frame through call_rpc_raw (XWB), and authenticate makes its sign-on RPCs
  # through both. Each stage raises what the test asks.
  def nesting_client(duz: PERSONA_DUZ)
    Class.new do
      prepend LiveStack::RefusalWatch

      # raw_raises: from call_rpc_raw. parse_raises: from call_rpc, after the
      # raw reply returned. context_raises / sign_on_raises: from create_context
      # / authenticate, after their inner calls returned. during: run once
      # inside call_rpc, between the raw reply and the answer.
      attr_accessor :duz, :raw_raises, :parse_raises, :context_raises, :sign_on_raises, :sign_on_duz, :during

      define_method(:initialize) { @duz = duz }

      define_method(:call_rpc_raw) do |rpc_name, *_params|
        raise @raw_raises if @raw_raises

        "raw #{rpc_name}"
      end

      define_method(:call_rpc) do |rpc_name, *params|
        call_rpc_raw(rpc_name, *params)
        if @during
          once, @during = @during, nil
          once.call
        end
        raise @parse_raises if @parse_raises

        [ rpc_name, *params ]
      end

      define_method(:create_context) do |option_name = "OR CPRS GUI CHART"|
        call_rpc_raw("XWB CREATE CONTEXT", option_name)
        raise @context_raises if @context_raises

        true
      end

      # The client's own rescue, as in production: a refused sign-on RPC is
      # answered with false, not raised.
      define_method(:authenticate) do |_access_code = nil, _verify_code = nil|
        begin
          call_rpc("XUS SIGNON SETUP")
          call_rpc_raw("XUS AV CODE")
        rescue RpmsRpc::Client::RpcRefusedError
          return false
        end
        raise @sign_on_raises if @sign_on_raises

        @duz = @sign_on_duz if @sign_on_duz
        true
      end
    end.new
  end

  def armed_nesting_client(duz: PERSONA_DUZ)
    nesting_client(duz: duz).tap { |client| LiveStack.arm!(client: client, persona_duz: PERSONA_DUZ) }
  end

  test "the watched methods are the four RPC entry points and the sign-on" do
    assert_equal WATCHED.sort, LiveStack::WATCHED.sort
  end

  test "a parsed call that reads its raw reply inside counts once" do
    client = armed_nesting_client

    assert_equal [ "ORWU USERINFO", "x" ], client.call_rpc("ORWU USERINFO", "x")

    evidence = LiveStack.take_evidence
    assert_equal 1, evidence.rpc_count, "the nested call_rpc_raw was counted by itself"
    assert_equal [], evidence.reasons
  end

  test "an M error raised by the outer call after its raw reply returned counts nothing" do
    client = armed_nesting_client
    failure = Client::RpcMError.new("<UNDEFINED>X+1^ORWU")
    client.parse_raises = failure

    raised = assert_raises(Client::RpcMError) { client.call_rpc("ORWU USERINFO") }

    assert_same failure, raised
    assert_equal 0, LiveStack.rpc_count, "the raw reply inside a call that ended in an M error was counted"
    evidence = LiveStack.take_evidence
    assert_equal 1, evidence.reasons.size
    assert_includes evidence.reasons.first, "ORWU USERINFO"
    assert_includes evidence.reasons.first, "M error"
  end

  test "a broker error raised by the outer call after its raw reply returned is not run and counts nothing" do
    client = armed_nesting_client
    client.parse_raises = Client::RpcRefusedError.new("broker said #{ACCESS};#{VERIFY}")

    error = assert_raises(LiveStack::NotRun) { client.call_rpc("ORWPT LIST ALL") }

    assert_not_run error, naming: "ORWPT LIST ALL"
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "the raw reply inside a refused call"
    assert_equal 1, evidence.reasons.size
    assert_includes evidence.reasons.first, "refused"
  end

  test "a nested call that is declined records nothing by itself: the outermost call is the one not run" do
    client = armed_nesting_client
    client.raw_raises = Client::RpcRefusedError.new("broker said #{ACCESS};#{VERIFY}")

    error = assert_raises(LiveStack::NotRun) { client.call_rpc("ORWPT LIST ALL") }

    assert_not_run error, naming: "ORWPT LIST ALL"
    assert_nil error.cause
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence
    assert_equal 1, evidence.reasons.size, "the nested call recorded a reason of its own"
    assert_includes evidence.reasons.first, "ORWPT LIST ALL"
  end

  test "a call on another thread while one is in progress is the outermost of its own thread" do
    client = armed_nesting_client
    client.during = -> { Thread.new { client.call_rpc("ORQQAL LIST", 4) }.value }

    client.call_rpc("ORWU USERINFO")

    evidence = LiveStack.take_evidence
    assert_equal 2, evidence.rpc_count, "one call on each thread, each counted once"
    assert_equal [], evidence.reasons
  end

  test "the watch decides again after a nested call has returned or raised" do
    client = armed_nesting_client
    client.call_rpc("ORWU USERINFO")
    client.parse_raises = Client::RpcMError.new("<UNDEFINED>X+1^ORWU")
    assert_raises(Client::RpcMError) { client.call_rpc("ORWU USERINFO") }
    client.parse_raises = nil
    LiveStack.take_evidence

    client.call_rpc("ORWU USERINFO")
    client.call_rpc("ORQQAL LIST", 4)

    evidence = LiveStack.take_evidence
    assert_equal 2, evidence.rpc_count
    assert_equal [], evidence.reasons
  end

  # -- a raw reply is not evidence ------------------------------------------

  test "an answered call_rpc_raw counts nothing and records nothing, whoever made it" do
    { "the armed client" => armed_client, "another client" => watched_client,
      "the armed client signed on as someone else" => armed_client(duz: "1") }.each do |who, client|
      LiveStack.take_evidence

      assert_equal [ "ORWU USERINFO", "x" ], client.call_rpc_raw("ORWU USERINFO", "x"), who

      assert_equal 0, LiveStack.rpc_count, "#{who}: an unparsed reply was counted"
      evidence = LiveStack.take_evidence
      assert_nothing_counted evidence, who
      assert_equal [], evidence.reasons, who
    end

    LiveStack.disarm!
    watched_client.call_rpc_raw("ORWU USERINFO")
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "nothing armed"
    assert_equal [], evidence.reasons, "nothing armed"
  end

  test "a scenario that only read raw replies did not run" do
    client = armed_client
    client.call_rpc_raw("ORWU USERINFO")

    reason = LiveStack.verdict(evidence: LiveStack.take_evidence, client: client, stack_client: client,
                               persona_duz: PERSONA_DUZ)

    assert_includes reason.to_s, "no RPC reached the stack"
  end

  test "a create_context that sends its frame through call_rpc_raw never counts and records no reason" do
    client = armed_nesting_client

    assert_equal true, client.create_context("OR CPRS GUI CHART")

    assert_equal 0, LiveStack.rpc_count, "the frame inside create_context was counted"
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "create_context over call_rpc_raw"
    assert_equal [], evidence.reasons
  end

  test "a create_context refused in its own frame or after it is not run and names the context option" do
    %i[raw_raises context_raises].each do |stage|
      LiveStack.take_evidence
      client = armed_nesting_client
      client.public_send("#{stage}=", Client::RpcRefusedError.new("broker said #{ACCESS};#{VERIFY}"))

      error = assert_raises(LiveStack::NotRun, stage.to_s) { client.create_context("OR CPRS GUI CHART") }

      assert_not_run error, naming: "OR CPRS GUI CHART"
      evidence = LiveStack.take_evidence
      assert_nothing_counted evidence, stage
      assert_equal 1, evidence.reasons.size, "#{stage}: the nested frame recorded a reason of its own"
      assert_includes evidence.reasons.first, "OR CPRS GUI CHART", stage.to_s
      assert_no_codes evidence.reasons.first
    end
  end

  # -- a sign-on inside a scenario is not the persona -----------------------

  test "a sign-on outside transparently is answered as it was, never counts, and says the scenario signed on as someone else" do
    client = armed_nesting_client

    assert_equal true, client.authenticate(ACCESS, VERIFY)

    assert_equal 0, LiveStack.rpc_count, "an RPC inside the sign-on was counted"
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "authenticate"
    assert_equal 1, evidence.reasons.size
    assert_includes evidence.reasons.first, "signed on as someone else"
    assert_no_codes evidence.reasons.first
  end

  test "a sign-on back to the persona's own DUZ is still not the persona" do
    client = armed_nesting_client
    client.sign_on_duz = PERSONA_DUZ

    client.authenticate(ACCESS, VERIFY)
    client.call_rpc("ORWU USERINFO")

    evidence = LiveStack.take_evidence
    assert_includes evidence.reasons.first.to_s, "signed on as someone else"
    assert_kind_of String, LiveStack.verdict(evidence: evidence, client: client, stack_client: client,
                                             persona_duz: PERSONA_DUZ)
  end

  test "a sign-on that raises outside transparently raises the original error and records the same reason" do
    [ Client::AuthenticationError, Client::ContextRefusedError, Client::ConnectionError ].each do |klass|
      LiveStack.take_evidence
      client = armed_nesting_client
      failure = klass.new("broker said #{ACCESS};#{VERIFY}")
      client.sign_on_raises = failure

      raised = assert_raises(klass) { client.authenticate(ACCESS, VERIFY) }

      assert_same failure, raised, "#{klass}: the sign-on's error must stay the original object, not a skip"
      evidence = LiveStack.take_evidence
      assert_nothing_counted evidence, klass
      assert_equal 1, evidence.reasons.size, klass.to_s
      assert_includes evidence.reasons.first, "signed on as someone else", klass.to_s
      assert_no_codes evidence.reasons.first
    end
  end

  test "an RPC refused inside a sign-on reaches the client's own rescue and records nothing by itself" do
    client = armed_nesting_client
    client.raw_raises = Client::RpcRefusedError.new("broker said #{ACCESS};#{VERIFY}")

    answer = nil
    assert_nothing_raised { answer = client.authenticate(ACCESS, VERIFY) }

    assert_equal false, answer, "the client's own rescue did not see the broker's error"
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence
    assert_equal 1, evidence.reasons.size
    assert_includes evidence.reasons.first, "signed on as someone else"
  end

  test "a sign-on inside transparently records nothing and counts nothing" do
    client = armed_nesting_client

    assert_equal true, LiveStack.transparently { client.authenticate(ACCESS, VERIFY) }

    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "authenticate inside transparently"
    assert_equal [], evidence.reasons

    failure = Client::AuthenticationError.new("refused")
    client.sign_on_raises = failure
    raised = assert_raises(Client::AuthenticationError) { LiveStack.transparently { client.authenticate(ACCESS, VERIFY) } }

    assert_same failure, raised
    assert_equal [], LiveStack.take_evidence.reasons
  end

  # -- a not-run is always said ---------------------------------------------

  test "not_run says its reason on stderr and still records it" do
    error = nil
    assert_output(nil, /^\[stack\] not run: the persona's sign-on was refused$/) do
      error = LiveStack.not_run("the persona's sign-on was refused")
    end

    assert_kind_of LiveStack::NotRun, error
    assert_equal "not run: the persona's sign-on was refused", error.message
    assert_equal [ "the persona's sign-on was refused" ], LiveStack.take_evidence.reasons
  end

  test "a declined RPC is said on stderr, without the broker's message or the codes" do
    client = armed_client(raises: Client::RpcRefusedError.new("broker said #{ACCESS};#{VERIFY}"))

    _out, err = capture_io { assert_raises(LiveStack::NotRun) { client.call_rpc("ORWPT LIST ALL", "A", 1) } }

    assert_match(/^\[stack\] not run: ORWPT LIST ALL /, err)
    assert_not_includes err, "broker said"
    assert_no_codes err
  end

  test "a refused create_context is said on stderr" do
    client = armed_client(raises: Client::ContextRefusedError.new("broker said #{ACCESS};#{VERIFY}"))

    _out, err = capture_io { assert_raises(LiveStack::NotRun) { client.create_context("OR CPRS GUI CHART") } }

    assert_match(/^\[stack\] not run: .*OR CPRS GUI CHART/, err)
    assert_no_codes err
  end

  # -- the mock is never evidence -------------------------------------------

  def mock_client(duz: PERSONA_DUZ)
    assert LiveStack.const_defined?(:MockWatch), "LiveStack::MockWatch is not defined"
    Class.new do
      prepend LiveStack::MockWatch

      attr_accessor :duz

      define_method(:initialize) { @duz = duz }
      define_method(:call_rpc) { |rpc_name, *params| [ rpc_name, *params ] }
    end.new
  end

  test "an answered call on the mock counts nothing and says it was the mock" do
    client = mock_client

    assert_equal [ "ORWU USERINFO", "x" ], client.call_rpc("ORWU USERINFO", "x")

    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "the mock"
    assert_equal 1, evidence.reasons.size
    assert_includes evidence.reasons.first, "mock"
    assert_no_codes evidence.reasons.first
  end

  test "the mock is not evidence even armed and signed on as the persona" do
    client = mock_client
    LiveStack.arm!(client: client, persona_duz: PERSONA_DUZ)

    client.call_rpc("ORWU USERINFO")
    client.call_rpc("ORQQAL LIST", 4)

    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence, "the armed mock"
    assert_operator evidence.reasons.size, :>=, 1
    assert_includes evidence.reasons.first, "mock"
    assert_kind_of String, LiveStack.verdict(evidence: evidence, client: client, stack_client: client,
                                             persona_duz: PERSONA_DUZ)
  end

  test "a scenario that read from the mock and from the stack did not run" do
    stack = armed_client
    stack.call_rpc("ORWU USERINFO")
    mock_client.call_rpc("ORWU USERINFO")

    reason = LiveStack.verdict(evidence: LiveStack.take_evidence, client: stack, stack_client: stack,
                               persona_duz: PERSONA_DUZ)

    assert_includes reason.to_s, "mock"
  end

  # -- the harness's own sign-on is transparent -----------------------------

  test "an error inside transparently is raised as the original object and leaves no evidence" do
    [
      Client::RpcRefusedError, Client::RpcNotAvailableError, Client::ConnectionError, Client::AuthenticationError,
      Client::RpcError, Client::ParseError, Client::RpcMError
    ].each do |klass|
      RPC_METHODS.each do |name|
        LiveStack.take_evidence
        failure = klass.new("refused")
        client = armed_client(raises: failure)

        raised = assert_raises(klass, "#{klass} from #{name}") do
          LiveStack.transparently { client.public_send(name, "XUS AV CODE") }
        end

        assert_same failure, raised, "#{klass} from #{name}"
        evidence = LiveStack.take_evidence
        assert_nothing_counted evidence, "#{klass} from #{name} inside transparently"
        assert_equal [], evidence.reasons, "#{klass} from #{name}"
      end
    end
  end

  test "a refused create_context inside transparently is raised as the original object and leaves no evidence" do
    failure = Client::ContextRefusedError.new("refused")
    client = armed_client(raises: failure)

    raised = assert_raises(Client::ContextRefusedError) do
      LiveStack.transparently { client.create_context("OR CPRS GUI CHART") }
    end

    assert_same failure, raised
    evidence = LiveStack.take_evidence
    assert_nothing_counted evidence
    assert_equal [], evidence.reasons
  end

  test "an answered call inside transparently neither counts nor records" do
    [ armed_client, watched_client, watched_client(duz: nil) ].each do |client|
      RPC_METHODS.each do |name|
        LiveStack.take_evidence

        answer = LiveStack.transparently { client.public_send(name, "XUS AV CODE", "x") }

        assert_equal [ "XUS AV CODE", "x" ], answer, "transparently answers with its block's value"
        evidence = LiveStack.take_evidence
        assert_nothing_counted evidence, "#{name} inside transparently"
        assert_equal [], evidence.reasons, name.to_s
      end
    end

    LiveStack.disarm!
    LiveStack.transparently { watched_client.call_rpc("XUS AV CODE") }
    assert_equal [], LiveStack.take_evidence.reasons, "nothing armed, inside transparently"
  end

  test "the watch is active again after transparently" do
    client = armed_client
    LiveStack.transparently { client.call_rpc("XUS AV CODE") }

    client.call_rpc("ORWU USERINFO")
    assert_operator LiveStack.take_evidence.rpc_count, :>=, 1, "an answered call after the block was not counted"

    client.raises = Client::RpcRefusedError.new("refused")
    error = assert_raises(LiveStack::NotRun) { client.call_rpc("ORWPT LIST ALL") }
    assert_not_run error, naming: "ORWPT LIST ALL"
    assert_equal 1, LiveStack.take_evidence.reasons.size
  end

  test "the watch is active again after transparently raises" do
    client = armed_client(raises: Client::RpcRefusedError.new("refused"))
    assert_raises(Client::RpcRefusedError) { LiveStack.transparently { client.call_rpc("XUS AV CODE") } }
    assert_raises(ArgumentError) { LiveStack.transparently { raise ArgumentError, "wrong argument" } }
    LiveStack.take_evidence

    error = assert_raises(LiveStack::NotRun) { client.call_rpc("ORWPT LIST ALL") }
    assert_not_run error, naming: "ORWPT LIST ALL"
    assert_equal 1, LiveStack.take_evidence.reasons.size

    client.raises = nil
    client.call_rpc("ORWU USERINFO")
    assert_operator LiveStack.take_evidence.rpc_count, :>=, 1, "an answered call after the block was not counted"
  end

  test "transparently is transparent on its own thread only" do
    client = armed_client(raises: Client::RpcRefusedError.new("refused"))

    elsewhere = LiveStack.transparently do
      Thread.new do
        client.call_rpc("ORWPT LIST ALL")
      rescue Exception => e # rubocop:disable Lint/RescueException -- NotRun's ancestry is cucumber's
        e
      end.value
    end

    assert_kind_of LiveStack::NotRun, elsewhere
    assert_equal 1, LiveStack.take_evidence.reasons.size
  end

  # -- the verdict: run only with evidence ----------------------------------

  Evidence = Struct.new(:rpc_count, :reasons)
  SignedOn = Struct.new(:duz)

  def verdict(evidence: Evidence.new(3, []), client: nil, stack_client: nil, persona_duz: "4321")
    stack_client ||= SignedOn.new("4321")
    client ||= stack_client
    LiveStack.verdict(evidence: evidence, client: client, stack_client: stack_client, persona_duz: persona_duz)
  end

  def assert_verdict(reason, containing:)
    assert_kind_of String, reason
    assert_includes reason, containing
    assert_no_codes reason
  end

  test "a scenario that reached the stack as the persona on the stack's client ran" do
    assert_nil verdict
    assert_nil verdict(evidence: Evidence.new(1, []))
    assert_nil verdict(stack_client: SignedOn.new(4321), persona_duz: "4321"), "DUZ is compared as text"
    assert_nil verdict(stack_client: SignedOn.new("4321"), persona_duz: 4321), "DUZ is compared as text"
  end

  test "a recorded reason is the verdict" do
    first = "ORWPT LIST ALL refused in the persona's context"
    reason = verdict(evidence: Evidence.new(2, [ first, "ORQQAL LIST not available" ]))

    assert_verdict reason, containing: first
  end

  test "a recorded reason is the verdict even when nothing else is right" do
    first = "ORWPT LIST ALL refused in the persona's context"
    reason = verdict(evidence: Evidence.new(0, [ first ]), client: SignedOn.new(nil), stack_client: SignedOn.new("4321"))

    assert_verdict reason, containing: first
  end

  test "a scenario that made no RPC did not run" do
    assert_verdict verdict(evidence: Evidence.new(0, [])), containing: "no RPC reached the stack"
  end

  test "a scenario on another client did not run, however alike the client" do
    stack_client = SignedOn.new("4321")
    twin = SignedOn.new("4321")
    assert_equal stack_client, twin

    assert_verdict verdict(client: twin, stack_client: stack_client), containing: "not the stack's client"
  end

  test "a scenario signed on as someone else did not run" do
    assert_verdict verdict(stack_client: SignedOn.new("1"), persona_duz: "4321"), containing: "not signed on as the persona"
  end

  test "a scenario with no signed-on user did not run" do
    [ nil, "" ].each do |duz|
      reason = verdict(stack_client: SignedOn.new(duz), persona_duz: duz)

      assert_verdict reason, containing: "not signed on as the persona"
    end
  end
end
