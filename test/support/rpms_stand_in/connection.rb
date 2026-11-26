# frozen_string_literal: true

require "rpms_rpc"

module RpmsStandIn
  # What RpmsRpc.client is in a test: a connection with no RPMS behind it.
  #
  # It is not a fake of RPMS: it knows no RPC and builds no reply. A call that
  # reaches it is recorded and answered with nothing, as a read of nothing on
  # file. The data a test needs is stated one level up, as an answer to the
  # read the engine makes (RpmsStandIn.answer). The one thing it can give back
  # is a reply recorded from the build (#replay).
  #
  # What it does keep is the engine's own plumbing, the question ADR 0013 asks
  # of a test double: who is signed on to this connection, which option context
  # is bound, and which calls went out on it.
  class Connection < RpmsRpc::Client
    # What a signed-on session is taken to hold, as a real client does.
    DEFAULT_CONTEXT = "OR CPRS GUI CHART"

    # Everything the engine asked of RPMS, in order, each with the DUZ the
    # connection was signed on as at the time. A call that reached the
    # connection is { rpc:, params:, context:, duz: }. A call the stand-in
    # answered (RpmsStandIn.answer) is
    # { answered: "RpmsRpc::Patient.find", args:, kwargs:, duz: }.
    attr_reader :received_calls
    # Every context bound, in order, including each restore.
    attr_reader :context_binds

    def initialize
      super(host: "rpms-stand-in.invalid", port: 0)
      @received_calls = []
      @context_binds = []
      @replays = {}
      @current_context = DEFAULT_CONTEXT
    end

    # The engine says so where it describes itself (the CapabilityStatement
    # discloses a synthetic dataset). No rpms-rpc client answers this.
    def stand_in? = true

    def connect(*) = (@open = true)
    def disconnect = (@open = false)
    def connected? = @open != false

    def create_context(option_name = DEFAULT_CONTEXT)
      @context_binds << option_name
      @current_context = option_name
      true
    end

    # Give back a reply recorded from the RPMS build, verbatim, to a call of
    # rpc_name (with first_param, when given). For a test of how a gateway
    # reads a real reply, and only for that: the lines are a capture, cited
    # where the test keeps it, never a reply written to fit. The connection
    # knows nothing about the RPC; rpms-rpc's own parser reads the lines.
    def replay(rpc_name, lines, first_param: nil)
      (@replays[rpc_name] ||= {})[first_param&.to_s] = lines
      self
    end

    def call_rpc(rpc_name, *params)
      record(rpc_name, params)
      captured = replayed(rpc_name, params)
      captured.is_a?(Array) ? RpmsRpc::Reply.from_wire(captured) : RpmsRpc::Reply.text(captured.to_s)
    end
    alias call_rpc_global_array call_rpc

    def call_rpc_raw(rpc_name, *params)
      record(rpc_name, params)
      Array(replayed(rpc_name, params)).join("\r\n")
    end

    def call_rpc_lines(rpc_name, *params)
      record(rpc_name, params)
      captured = replayed(rpc_name, params)
      RpmsRpc::Reply.from_wire(captured.is_a?(String) ? captured.b.split(/\r\n|\r|\n/) : Array(captured))
    end

    private

    # The capture for this call: the one for its first parameter, else the
    # one for any call of the RPC, else nothing.
    def replayed(rpc_name, params)
      captures = @replays[rpc_name] or return nil
      captures.fetch(params.first.to_s) { captures[nil] }
    end

    def record(rpc_name, params)
      @received_calls << { rpc: rpc_name, params: params, context: current_context, duz: duz }
    end
  end
end
