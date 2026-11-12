# frozen_string_literal: true

require "cucumber/core/test/result"

# The binding behind `cucumber --profile stack` (#962). A stack run takes its
# whole binding from VARIABLES, signs on as that one persona, and is ready only
# when the persona does not hold XUPROGMODE. Anything it cannot confirm leaves
# it not ready, and the run reports @live scenarios as not run. A ready run
# reports a scenario as run only with evidence (see verdict). Reasons are fixed
# texts, RPC names and variable names: never a broker message, which could
# carry the codes.
module LiveStack
  VARIABLES = %w[RPMS_IP RPMS_PORT RPMS_BROKER RPMS_ACCESS RPMS_VERIFY].freeze
  BROKERS = %w[cia xwb].freeze
  PROGRAMMER_KEY = "XUPROGMODE"
  # Read by the broker client but not part of the binding: a run that carries
  # it would not be bound by VARIABLES alone.
  FOREIGN = %w[RPMS_UCI].freeze
  WATCHED = %i[call_rpc call_rpc_raw call_rpc_global_array create_context].freeze

  # The persona's codes leave only through access_code and verify_code.
  class Binding
    attr_reader :host, :port, :broker, :access_code, :verify_code

    def initialize(host, port, broker, access_code, verify_code)
      @host, @port, @broker, @access_code, @verify_code = host, port, broker, access_code, verify_code
    end

    def inspect = "#<LiveStack::Binding #{broker} #{host}:#{port}>"
    alias_method :to_s, :inspect
    def pretty_print(pp) = pp.text(inspect)
    def as_json(*) = inspect
    def to_json(*arguments) = as_json.to_json(*arguments)
    def encode_with(coder) = coder.scalar = inspect
  end

  Status = Struct.new(:reason, :persona_duz) do
    def ready? = reason.nil?
  end

  Evidence = Data.define(:rpc_count, :reasons)

  # The stack declined a step: the scenario is skipped as not run, not failed.
  class NotRun < Cucumber::Core::Test::Result::Skipped; end

  # Prepended onto the broker client class. A call that returned counts as
  # evidence only on the armed client signed on as the persona (LiveStack.arm!);
  # any other answered call records why it does not count. A broker error the
  # stack would not or could not answer records a reason and raises NotRun. A
  # routine that ran and failed (RpcMError) and every other error pass through
  # unchanged. Inside LiveStack.transparently the watch stands aside.
  module RefusalWatch
    DECLINED = {
      RpmsRpc::Client::RpcRefusedError => "refused in the persona's context",
      RpmsRpc::Client::RpcNotAvailableError => "not available on the stack",
      RpmsRpc::Client::ConnectionError => "lost the connection to the stack",
      RpmsRpc::Client::AuthenticationError => "was not authenticated on the stack"
    }.freeze

    def call_rpc(rpc_name, *params) = LiveStack.watch(self, rpc_name) { super }
    def call_rpc_raw(rpc_name, *params) = LiveStack.watch(self, rpc_name) { super }
    def call_rpc_global_array(rpc_name, *params) = LiveStack.watch(self, rpc_name) { super }

    # Never evidence: on CIA it sends no frame.
    def create_context(*arguments)
      super
    rescue RpmsRpc::Error
      raise if LiveStack.transparent?

      option = arguments.first || "the default context"
      raise LiveStack.not_run("context #{option} could not be created in the persona's context"), cause: nil
    end

    # A watched method the client itself lacks (XwbClient has no
    # call_rpc_global_array) stays absent: callers branch on respond_to?.
    def respond_to?(name, include_all = false)
      return super unless WATCHED.include?(name.to_sym)

      super && !method(name).super_method.nil?
    end
  end

  EVIDENCE = { rpc_count: 0, reasons: [] }
  ARMED = {}
  EVIDENCE_LOCK = Mutex.new
  TRANSPARENT = :live_stack_transparent

  module_function

  def requested?(env) = env["LIVE_STACK"] == "1"

  def missing(env)
    VARIABLES.select do |name|
      value = env[name].to_s.strip
      case name
      when "RPMS_PORT" then !value.match?(/\A\d+\z/) || !(1..65_535).cover?(value.to_i)
      when "RPMS_BROKER" then !BROKERS.include?(value)
      else value.empty?
      end
    end
  end

  def binding(env)
    return unless missing(env).empty?

    Binding.new(env["RPMS_IP"].strip, Integer(env["RPMS_PORT"].strip, 10), env["RPMS_BROKER"].strip,
                env["RPMS_ACCESS"], env["RPMS_VERIFY"])
  end

  def prepare(env, connect: method(:connect), authenticate: method(:authenticate),
              held_keys: ->(names) { RpmsRpc::Authentication.held_keys(names) })
    absent = missing(env)
    return Status.new("missing #{absent.join(', ')}") unless absent.empty?

    foreign = FOREIGN.select { |name| env.key?(name) }
    return Status.new("#{foreign.join(', ')} set: the binding is #{VARIABLES.join(', ')} alone") unless foreign.empty?

    before = RpmsRpc.configuration.client
    status = sign_on(binding(env), connect, authenticate, held_keys)
    restore(before) unless status.ready?
    status
  end

  def sign_on(bound, connect, authenticate, held_keys)
    begin
      connect.call(bound)
    rescue StandardError
      return Status.new("broker unreachable at RPMS_IP:RPMS_PORT")
    end

    result = authenticate.call(bound.access_code, bound.verify_code)
    unless result.success?
      return Status.new(result.error == Lakeraven::EHR::AuthenticationService::CONTEXT_REFUSED ? "context refused" : "sign-on refused")
    end

    keys = held_keys.call([ PROGRAMMER_KEY ])
    return Status.new("could not ask whether the persona holds #{PROGRAMMER_KEY}") if keys.nil?
    return Status.new("the persona holds #{PROGRAMMER_KEY}") if keys.include?(PROGRAMMER_KEY)

    Status.new(nil, result.value[:duz].to_s)
  rescue StandardError
    Status.new("sign-on failed")
  end

  def connect(bound)
    RpmsRpc.configure { |c| c.client = RpmsRpc.client_for(bound.broker, host: bound.host, port: bound.port) }
    RpmsRpc.client.connect
  end

  def authenticate(access_code, verify_code)
    Lakeraven::EHR::AuthenticationService.new.authenticate(access_code: access_code, verify_code: verify_code)
  end

  # Fall back to exactly the run without the binding: a client prepare
  # installed is closed, and the one from before is back.
  def restore(before)
    installed = RpmsRpc.configuration.client
    return if installed.equal?(before)

    begin
      installed.disconnect if installed.respond_to?(:disconnect)
    rescue StandardError
      nil
    end
    RpmsRpc.configure { |c| c.client = before }
  end

  def not_run_message(status) = "not run: #{status.reason}"

  # -- evidence: what a scenario did against the stack ----------------------

  # The client and DUZ a call must be on to count as the persona's.
  def arm!(client:, persona_duz:)
    EVIDENCE_LOCK.synchronize { ARMED.replace(client: client, persona_duz: persona_duz.to_s) }
  end

  def disarm! = EVIDENCE_LOCK.synchronize { ARMED.clear }

  # Runs the block with the watch inactive on this thread: calls neither
  # count nor record, and errors propagate as they were raised.
  def transparently
    before = Thread.current.thread_variable_get(TRANSPARENT)
    Thread.current.thread_variable_set(TRANSPARENT, true)
    yield
  ensure
    Thread.current.thread_variable_set(TRANSPARENT, before)
  end

  def transparent? = Thread.current.thread_variable_get(TRANSPARENT) == true

  def watch(client, rpc_name)
    return yield if transparent?

    begin
      answer = yield
    rescue RpmsRpc::Client::RpcMError
      raise
    rescue RpmsRpc::Error => e
      declined = RefusalWatch::DECLINED.find { |klass, _| e.is_a?(klass) }&.last || "failed at the broker"
      # cause: nil, so the broker's message does not travel with the skip.
      raise not_run("#{rpc_name} #{declined}"), cause: nil
    end
    witness(client)
    answer
  end

  # Counts an answered call, or records why it is not the persona's.
  def witness(client)
    EVIDENCE_LOCK.synchronize do
      if ARMED.empty?
        EVIDENCE[:reasons] << "an RPC answered while the watch was not armed"
      elsif client.equal?(ARMED[:client]) && client.duz.to_s == ARMED[:persona_duz]
        EVIDENCE[:rpc_count] += 1
      else
        EVIDENCE[:reasons] << "an RPC answered on what is not the persona's client"
      end
    end
  end

  def rpc_count = EVIDENCE_LOCK.synchronize { EVIDENCE[:rpc_count] }

  # Records the reason and answers the NotRun to raise in place of the error.
  def not_run(reason)
    EVIDENCE_LOCK.synchronize { EVIDENCE[:reasons] << reason }
    NotRun.new("not run: #{reason}")
  end

  def take_evidence
    EVIDENCE_LOCK.synchronize do
      Evidence.new(rpc_count: EVIDENCE[:rpc_count], reasons: EVIDENCE[:reasons].dup).tap do
        EVIDENCE[:rpc_count] = 0
        EVIDENCE[:reasons].clear
      end
    end
  end

  # nil when the scenario ran against the stack as the persona, else why not.
  def verdict(evidence:, client:, stack_client:, persona_duz:)
    return evidence.reasons.first unless evidence.reasons.empty?
    return "no RPC reached the stack" if evidence.rpc_count.zero?
    return "the scenario's broker client is not the stack's client" unless client.equal?(stack_client)

    duz = client.duz.to_s
    "the stack's client is not signed on as the persona" if duz.empty? || duz != persona_duz.to_s
  end
end
