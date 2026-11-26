# frozen_string_literal: true

require_relative "stub_helpers"
require_relative "rpms_stand_in/connection"

# lakeraven-ehr's own stand-in for RPMS in tests (#1207).
#
# It stands at the engine's seam, not at RPMS's. A test says what a gateway
# (app/gateways) answers, in the engine's own terms:
#
#   RpmsStandIn.answer(Lakeraven::EHR::PatientGateway, :find, 1, with: patient)
#   RpmsStandIn.answer(Lakeraven::EHR::ConditionGateway, :for_patient) { |dfn| ... }
#
# It never says how RPMS replies to an RPC. Where engine code reaches rpms-rpc
# without a gateway, or a gateway's own test needs what rpms-rpc hands it, the
# same call answers the rpms-rpc method the engine calls, with the facts that
# method returns:
#
#   RpmsStandIn.answer(RpmsRpc::Problem, :for_patient, 1, with: [ { ien: 4, ... } ])
#
# A call nothing answers runs the real code against RpmsStandIn::Connection,
# which records it and answers nothing on file. The answers hold only while
# that connection is RpmsRpc.client: a test that scopes a client of its own
# gets the real code on its client.
#
# A pass here is evidence about the engine's logic only. What RPMS answers is
# proven by the @live Cucumber profile against the RPMS image.
module RpmsStandIn
  ANY_ARGS = Object.new.freeze
  Entry = Struct.new(:args, :value, :block)

  @answers = {}
  @calls = {}
  @restores = []
  @state = {}

  class << self
    # The connection RpmsRpc.client is while the stand-in is installed.
    attr_reader :connection

    # A fresh stand-in: no answers, no recorded calls, a new connection as
    # RpmsRpc.client. Yields itself so a caller can state its answers.
    def install!
      reset!
      @connection = Connection.new
      RpmsRpc.configure { |config| config.client = @connection }
      yield self if block_given?
      self
    end

    # receiver.method_name answers `with` (or the block's result, called with
    # the call's own arguments). With args, only for a call with those
    # positional arguments; an Integer and its String are the same argument,
    # as a DFN is to a gateway. The newest matching answer wins, and an answer
    # for named arguments wins over one for any.
    def answer(receiver, method_name, *args, with: nil, &block)
      key = [ receiver, method_name.to_sym ]
      intercept(receiver, method_name.to_sym) unless @answers.key?(key)
      (@answers[key] ||= []).unshift(Entry.new(args.empty? ? ANY_ARGS : normalize(args), with, block))
      self
    end

    # Each call receiver.method_name received while it had an answer:
    # { args:, kwargs: }.
    def calls(receiver, method_name)
      @calls.fetch([ receiver, method_name.to_sym ], [])
    end

    def reset!
      @restores.reverse_each(&:call)
      @restores = []
      @answers = {}
      @calls = {}
      @state = {}
      @connection = nil
    end

    def installed? = !@connection.nil?

    # What the helpers built on #answer (sign-on users, sensitive records)
    # keep between calls. Emptied with every reset.
    attr_reader :state

    private

    def intercept(receiver, method_name)
      original = receiver.method(method_name)
      stand_in = self
      @restores << StubHelpers.install_singleton_method(receiver, method_name) do |*args, **kwargs, &blk|
        stand_in.send(:dispatch, [ receiver, method_name ], original, args, kwargs, blk)
      end
    end

    def dispatch(key, original, args, kwargs, blk)
      # The stand-in answers for its own connection only. A test that hands
      # the engine a client of its own (RpmsRpc.with_client, use_broker) is
      # asking that client, so the real code runs against it.
      return original.call(*args, **kwargs, &blk) unless on_stand_in_connection?

      (@calls[key] ||= []) << { args: args, kwargs: kwargs }
      entries = @answers.fetch(key, [])
      wanted = normalize(args)
      entry = entries.find { |e| e.args == wanted } || entries.find { |e| e.args.equal?(ANY_ARGS) }
      return original.call(*args, **kwargs, &blk) unless entry

      # An answered call is still the engine asking RPMS for something, so it
      # is on the connection's record with the calls that went unanswered: a
      # test that proves "RPMS was not asked" counts both.
      @connection.received_calls << { answered: "#{key[0].name}.#{key[1]}", args: args, kwargs: kwargs, duz: @connection.duz }
      return entry.block.call(*args, **kwargs) if entry.block

      entry.value
    end

    def on_stand_in_connection?
      (RpmsRpc.scoped_client || RpmsRpc.configuration.client).equal?(@connection)
    end

    def normalize(args) = args.map { |arg| arg.is_a?(Integer) ? arg.to_s : arg }
  end
end

require_relative "rpms_stand_in/sign_on"
require_relative "rpms_stand_in/sensitive_records"
require_relative "rpms_stand_in/baseline"
