# frozen_string_literal: true

# The binding behind `cucumber --profile stack` (#962). A stack run takes its
# whole binding from VARIABLES, signs on as that one persona, and is ready only
# when the persona does not hold XUPROGMODE. Anything it cannot confirm leaves
# it not ready, and the run reports @live scenarios as not run. Reasons are
# fixed texts and variable names: never a broker message, which could carry
# the codes.
module LiveStack
  VARIABLES = %w[RPMS_IP RPMS_PORT RPMS_BROKER RPMS_ACCESS RPMS_VERIFY].freeze
  BROKERS = %w[cia xwb].freeze
  PROGRAMMER_KEY = "XUPROGMODE"

  Binding = Struct.new(:host, :port, :broker, :access_code, :verify_code) do
    def inspect = "#<LiveStack::Binding #{broker} #{host}:#{port}>"
    alias_method :to_s, :inspect
  end

  Status = Struct.new(:reason) do
    def ready? = reason.nil?
  end

  # A broker call refused in the persona's context, recorded by RPC name.
  module RefusalWatch
    def call_rpc(rpc_name, *params)
      super
    rescue RpmsRpc::Client::RpcRefusedError
      LiveStack.record_refusal(rpc_name)
      raise
    end
  end

  REFUSALS = []
  REFUSALS_LOCK = Mutex.new

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

    before = RpmsRpc.configuration.client
    status = Status.new(sign_on_reason(binding(env), connect, authenticate, held_keys))
    # Fall back to exactly the run without the binding: no client of ours.
    uninstall if !status.ready? && !RpmsRpc.configuration.client.equal?(before)
    status
  end

  def sign_on_reason(bound, connect, authenticate, held_keys)
    begin
      connect.call(bound)
    rescue RpmsRpc::Error, SystemCallError, IOError
      return "broker unreachable at RPMS_IP:RPMS_PORT"
    end

    result = authenticate.call(bound.access_code, bound.verify_code)
    unless result.success?
      return result.error == Lakeraven::EHR::AuthenticationService::CONTEXT_REFUSED ? "context refused" : "sign-on refused"
    end

    keys = held_keys.call([ PROGRAMMER_KEY ])
    return "could not ask whether the persona holds #{PROGRAMMER_KEY}" if keys.nil?
    return "the persona holds #{PROGRAMMER_KEY}" if keys.include?(PROGRAMMER_KEY)

    nil
  rescue RpmsRpc::Error, SystemCallError, IOError
    "sign-on failed"
  end

  def connect(bound)
    RpmsRpc.configure { |c| c.client = RpmsRpc.client_for(bound.broker, host: bound.host, port: bound.port) }
    RpmsRpc.client.connect
  end

  def authenticate(access_code, verify_code)
    Lakeraven::EHR::AuthenticationService.new.authenticate(access_code: access_code, verify_code: verify_code)
  end

  def uninstall
    RpmsRpc.configure { |c| c.client = nil }
  end

  def not_run_message(status) = "not run: #{status.reason}"

  def record_refusal(rpc_name)
    REFUSALS_LOCK.synchronize { REFUSALS << rpc_name.to_s }
  end

  def take_refusals
    REFUSALS_LOCK.synchronize { REFUSALS.dup.tap { REFUSALS.clear } }
  end
end
