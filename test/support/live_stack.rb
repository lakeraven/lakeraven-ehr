# frozen_string_literal: true

require "cucumber/core/test/result"
require "active_support"
require "active_support/testing/time_helpers"

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
  WATCHED = %i[call_rpc call_rpc_raw call_rpc_global_array create_context authenticate].freeze

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

  # Prepended onto the broker client class. Only the outermost watched call on
  # a thread decides (LiveStack.watch). A parsed call that returned counts as
  # evidence only on the armed client signed on as the persona (LiveStack.arm!);
  # any other answered parsed call records why it does not count. A raw reply
  # or a created context is never evidence. A routine that ran and failed
  # (RpcMError) records an M error and raises unchanged; any other broker error
  # records a reason and raises NotRun; every other error passes through
  # unchanged. A sign-on records that the scenario signed on as someone else
  # and answers as it did. Inside LiveStack.transparently the watch stands aside.
  module RefusalWatch
    DECLINED = {
      RpmsRpc::Client::RpcRefusedError => "refused in the persona's context",
      RpmsRpc::Client::RpcNotAvailableError => "not available on the stack",
      RpmsRpc::Client::ConnectionError => "lost the connection to the stack",
      RpmsRpc::Client::AuthenticationError => "was not authenticated on the stack"
    }.freeze

    def call_rpc(rpc_name, *params) = LiveStack.watch(self, rpc_name, :parsed) { super }
    def call_rpc_raw(rpc_name, *params) = LiveStack.watch(self, rpc_name, :raw) { super }
    def call_rpc_global_array(rpc_name, *params) = LiveStack.watch(self, rpc_name, :parsed) { super }
    def create_context(*arguments) = LiveStack.watch(self, arguments.first || "the default context", :context) { super }
    def authenticate(*arguments, **options) = LiveStack.watch(self, "the sign-on", :sign_on) { super }

    # A watched method the client itself lacks (XwbClient has no
    # call_rpc_global_array) stays absent: callers branch on respond_to?.
    def respond_to?(name, include_all = false)
      return super unless WATCHED.include?(name.to_sym)

      super && !method(name).super_method.nil?
    end
  end

  # Prepended onto the mock client class in a ready stack run: an answer from
  # the mock, through any of its read paths, is never evidence. Each read
  # records that the mock answered, whether it returned or raised, and answers
  # or raises unchanged.
  module MockWatch
    READS = %i[call_rpc call_rpc_lines call_rpc_global_array].freeze

    READS.each do |read|
      define_method(read) do |rpc_name, *params|
        LiveStack.watch(self, rpc_name, :mock) { super(rpc_name, *params) }
      end
    end
  end

  # Prepended onto Module in a ready stack run: a define_singleton_method that
  # replaces a method a named module already answers (its own, private or
  # inherited) is a gateway stub, and LiveStack.stub_installed records it. A
  # new method, an anonymous module or an object that is not a Module is not
  # a stub. Defines and answers exactly as unwatched; errors pass through.
  # The module's name and what it answers are read from Module and Kernel,
  # never from the module's own overrides.
  module StubWatch
    def define_singleton_method(method_name, *body, &block)
      replaces = LiveStack.replaces?(self, method_name)
      defined = super
      LiveStack.stub_installed(self, method_name) if replaces
      defined
    end
  end

  # Prepended onto ActiveSupport::Testing::SimpleStubs in a ready stack run:
  # travel_to, travel and freeze_time move the clock through stub_object and
  # put it back through unstub_all!, which is not a gateway stub. Each runs
  # with the watch aside, and answers and raises exactly as unwatched.
  module TimeStubWatch
    def stub_object(*arguments, &block) = LiveStack.transparently { super }
    def unstub_all!(*arguments, &block) = LiveStack.transparently { super }
  end

  EVIDENCE = { rpc_count: 0, reasons: [] }
  ARMED = {}
  EVIDENCE_LOCK = Mutex.new
  TRANSPARENT = :live_stack_transparent
  WATCHING = :live_stack_watching

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

  # The ready run's watches: arms the persona's client, and prepends
  # RefusalWatch onto its class, MockWatch onto the mock, StubWatch onto
  # Module and TimeStubWatch onto SimpleStubs, each once.
  def install!(client:, persona_duz:, mock_class: RpmsRpc::MockClient, module_class: Module,
               time_stubs_class: ActiveSupport::Testing::SimpleStubs)
    arm!(client: client, persona_duz: persona_duz)
    [ [ client.class, RefusalWatch ], [ mock_class, MockWatch ], [ module_class, StubWatch ],
      [ time_stubs_class, TimeStubWatch ] ].each do |klass, watch|
      klass.prepend(watch) unless klass.ancestors.include?(watch)
    end
  end

  # Module#name of receiver, whatever receiver answers to name itself.
  def module_name(receiver) = Module.instance_method(:name).bind_call(receiver)

  # Whether a define_singleton_method of method_name on receiver replaces a
  # method a named module already answers (its own, private or inherited).
  def replaces?(receiver, method_name)
    Module === receiver && !module_name(receiver).nil? &&
      Kernel.instance_method(:respond_to?).bind_call(receiver, method_name, true)
  end

  # Records a gateway stub on a Module while the watch is armed and not aside.
  def stub_installed(receiver, method_name)
    return unless Module === receiver && !transparent?
    return if EVIDENCE_LOCK.synchronize { ARMED.empty? }

    record("a gateway was stubbed: #{module_name(receiver)}.#{method_name}")
  end

  # Signs the persona on again through client, with the watch aside (so the
  # sign-on's own rescues see the broker's errors as in production), and
  # checks XUPROGMODE again. Answers [result, reason]: reason is nil, or a
  # fixed text, never the broker's message.
  def re_sign_on(client:, binding:, authenticate: method(:authenticate),
                 held_keys: ->(names) { RpmsRpc::Authentication.held_keys(names) })
    result = nil
    reason = transparently do
      RpmsRpc.with_client(client) do
        result = authenticate.call(binding.access_code, binding.verify_code)
        if !result.success? then "the persona's sign-on was refused"
        elsif held_keys.call([ PROGRAMMER_KEY ]) != []
          "the persona holds #{PROGRAMMER_KEY}, or it could not be asked"
        end
      end
    rescue StandardError
      "the persona's sign-on failed"
    end
    [ result, reason ]
  end

  # Clears the client's signed-on identity, so the verdict's DUZ check fails
  # every later scenario, and skips this one as not run.
  def decline_sign_on!(client, reason)
    client.clear_authenticated if client.respond_to?(:clear_authenticated)
    raise not_run(reason), cause: nil
  end

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

  # Runs a watched call. Only the outermost watched frame on this thread
  # decides, after it returns or raises. A frame inside it (CiaClient#call_rpc
  # reads through call_rpc_raw, authenticate signs on through both) answers and
  # raises exactly as unwatched, so a client's own rescue still sees the
  # broker's error. kind is :parsed, :raw, :context, :sign_on or :mock.
  def watch(client, name, kind)
    return yield if transparent? || Thread.current.thread_variable_get(WATCHING)

    begin
      Thread.current.thread_variable_set(WATCHING, true)
      answer = yield
    rescue RpmsRpc::Error => e
      decline(e, name, kind)
    ensure
      Thread.current.thread_variable_set(WATCHING, nil)
      record("the scenario signed on as someone else") if kind == :sign_on
      record("#{name} was answered by the mock, not the stack") if kind == :mock
    end
    witness(client) if kind == :parsed
    answer
  end

  # Raises in place of a broker error from an outermost watched call: the
  # original from a sign-on, the mock or a routine that ran and failed (which
  # records an M error), else NotRun. cause: nil, so the broker's message does
  # not travel with the skip.
  def decline(error, name, kind)
    raise error if %i[sign_on mock].include?(kind)
    raise not_run("context #{name} could not be created in the persona's context"), cause: nil if kind == :context

    if error.is_a?(RpmsRpc::Client::RpcMError)
      record("#{name} raised an M error")
      raise error
    end

    declined = RefusalWatch::DECLINED.find { |klass, _| error.is_a?(klass) }&.last || "failed at the broker"
    raise not_run("#{name} #{declined}"), cause: nil
  end

  def record(reason) = EVIDENCE_LOCK.synchronize { EVIDENCE[:reasons] << reason }

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

  # Records and says the reason, and answers the NotRun to raise in place of
  # the error.
  def not_run(reason)
    record(reason)
    warn "[stack] not run: #{reason}"
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
