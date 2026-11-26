# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"

# Integration TestResponse never picked up the success? alias LiveTestResponse
# has. The consent specification calls response.success? for a non-2xx check.
unless ActionDispatch::TestResponse.method_defined?(:success?)
  ActionDispatch::TestResponse.alias_method :success?, :successful?
end

# Engine pages link the Tailwind build (tailwind.css), and a missing build is
# a template error on any page that links it. `rails test:prepare` builds
# it in an app, but an engine's test runner never calls test:prepare, so build
# it here: once per run, from the current views, and loudly when it fails.
# Cucumber loads this file too.
Tailwindcss::Engines.bundle
system(*Tailwindcss::Commands.compile_command(silent: false), exception: true)

require_relative "support/supplemental_provider_config_helper"
require_relative "support/global_store_isolation"
require_relative "support/host_role_expectations"
require_relative "support/fake_gateway"
require_relative "support/stub_helpers"
require_relative "support/scheduling_setup_stubs"
require_relative "support/registration_form_helper"
require_relative "support/browser_form_helper"
require_relative "support/patient_profile_stubs"
require_relative "support/ihs_feature_availability_test_helper"
require_relative "support/rpms_stand_in"
require_relative "support/rate_limit_test_helper"
require_relative "support/live_stack"
require_relative "support/sensitive_patient_access_seeds"

# The suite runs on the engine's own stand-in for RPMS (support/rpms_stand_in.rb):
# a pass proves the engine's logic, not what RPMS answers.
#
# LIVE_RPMS=1 runs it against a real broker instead
# (cucumber --profile live). The broker is the one the engine built at boot
# from config/rpms.yml (VISTA_BROKER, VISTA_RPC_HOST, VISTA_RPC_PORT), the
# path a deployed app takes, and the run signs on through the engine's own
# AuthenticationService as LIVE_RPMS_ACCESS / LIVE_RPMS_VERIFY. It never falls
# back to the mock: a missing broker or a refused sign-on aborts the run.
#
# LIVE_STACK=1 (cucumber --profile stack, #962) binds the run from
# LiveStack::VARIABLES alone and signs on as that persona, who must not hold
# XUPROGMODE. A stack it cannot confirm runs on the mock, and @live scenarios
# report not run (features/support/live_stack.rb).
LIVE_STACK = LiveStack.requested?(ENV) ? LiveStack.prepare(ENV) : nil
LIVE_STACK_BINDING = (LiveStack.binding(ENV) if LIVE_STACK&.ready?)
LIVE_RPMS = ENV["LIVE_RPMS"] == "1" || LIVE_STACK&.ready? == true
warn "[stack] #{LiveStack.not_run_message(LIVE_STACK)}" if LIVE_STACK && !LIVE_STACK.ready?
if LIVE_RPMS
  abort "LIVE_RPMS=1: no broker configured (set VISTA_RPC_HOST)" unless RpmsRpc.configuration.client

  module LiveRpmsSession
    module_function

    # Sign the shared broker session on as the run's persona. Scenarios that
    # sign on as someone else call this afterwards, since one process holds
    # one broker identity (rpms-rpc#234).
    def sign_on!
      if LIVE_STACK_BINDING
        stack_sign_on!
      else
        result = Lakeraven::EHR::AuthenticationService.new.authenticate(
          access_code: ENV.fetch("LIVE_RPMS_ACCESS"), verify_code: ENV.fetch("LIVE_RPMS_VERIFY")
        )
        abort "LIVE_RPMS=1: sign-on refused: #{result.error}" unless result.success?
        result
      end
    end

    # The stack persona again, and again without XUPROGMODE, for scenarios
    # that signed on as someone else (LiveStack.re_sign_on). Called from an
    # After hook: a failure clears LIVE_STACK_CLIENT's identity and raises
    # NotRun (LiveStack.decline_sign_on!), so this scenario is skipped as not
    # run and every later one fails the verdict's DUZ check.
    def stack_sign_on!
      result, reason = LiveStack.re_sign_on(client: LIVE_STACK_CLIENT, binding: LIVE_STACK_BINDING)
      LiveStack.decline_sign_on!(LIVE_STACK_CLIENT, reason) if reason
      result
    end
  end

  if LIVE_STACK_BINDING
    # prepare signed the persona on and checked XUPROGMODE: no second sign-on.
    # The client the persona is signed on through: a call counts as evidence,
    # and a scenario as run, only on this very object (LiveStack.verdict).
    # install! arms the watch and watches the client, the mock and gateway
    # stubs.
    LIVE_STACK_CLIENT = RpmsRpc.configuration.client
    LiveStack.install!(client: LIVE_STACK_CLIENT, persona_duz: LIVE_STACK.persona_duz)
    warn "[stack] ready: #{LIVE_STACK_BINDING.broker} #{LIVE_STACK_BINDING.host}:#{LIVE_STACK_BINDING.port}"
  else
    live_user = LiveRpmsSession.sign_on!.value
    settings = Lakeraven::EHR::Engine.rpms_settings
    warn "[live] RPMS #{settings[:broker]} #{settings[:host]}:#{settings[:port]} signed on as #{live_user.inspect[0, 120]}"
  end
else
  RpmsStandIn.install_baseline!
  # The stand-in has no division, so the registration settings read
  # (REGISTRATION PARAMETERS, #980/#981) answers as a site with none set:
  # nothing required beyond the forms' own rules, every section asked. A test
  # that needs a site's settings stubs RegistrationSettingsGateway.current.
  Lakeraven::EHR::RegistrationSettingsGateway.reader = -> { Lakeraven::EHR::RegistrationSiteSettings.not_on_file }
  # The stand-in has no server clock, so the site's clock (ORWU DT "NOW",
  # #1065, #1114) is the app's. A test that needs the site's clock elsewhere
  # sets SiteTime.reader, or clears it and answers RpmsRpc::Orwu.fileman_datetime. The process
  # runs in UTC, as CI and the deployed host do, so the app's date
  # (Date.current) and its wall clock (Time.now) are the same day on any
  # workstation.
  ENV["TZ"] = "UTC"
  # Guarded so red-before-green can load this helper against the base app
  # code, where SiteTime does not exist yet; drop the guard once it is on main.
  Lakeraven::EHR::SiteTime.reader = -> { Time.now } if defined?(Lakeraven::EHR::SiteTime)
end

# Scripted RPC broker for the BPRM reg/sched/ADT twin gateway tests.
#
# The reg/sched gateways call RpmsRpc.client.call_rpc(rpc_name, *params)
# directly and parse the caret response, so a gateway unit test just needs a
# client that (a) records the calls it received and (b) returns a scripted
# response per RPC name. `on(rpc, *responses)` queues responses (a single
# response is reused for every call; multiple are consumed in order — handy
# for composite flows like rebook). `raise_with` simulates a broker-unreachable
# socket error. Swap it in with `use_broker(fake) { ... }` from a test.
class FakeBroker
  attr_reader :calls

  def initialize
    @calls = []
    @responses = {}
    @raise = nil
    @default = ""
  end

  def on(rpc, *responses)
    @responses[rpc] = responses
    self
  end

  def raise_with(error)
    @raise = error
    self
  end

  def call_rpc(rpc, *params)
    @calls << { rpc: rpc, params: params }
    raise @raise if @raise

    queue = @responses[rpc]
    return @default if queue.nil? || queue.empty?
    return queue.first if queue.length == 1

    queue.shift
  end

  # The REAL clients (BmxClient, CiaClient) expose a public `call_rpc_raw`
  # that executes an RPC without response parsing. The fake models it so a
  # wrapper that forwards it can be SEEN doing so — a mock without the real
  # client's surface cannot express the bypass (SOFTWARE-FACTORY: a mock that
  # cannot express a failure is not evidence against it).
  def call_rpc_raw(rpc, *params)
    call_rpc(rpc, *params)
  end

  # Also on the real clients' public surface; must never be reachable
  # through an audited wrapper.
  def read_response = @default

  # The REST of the production clients' public surface (BmxClient/CiaClient:
  # connection, credential and raw-execution methods), as LOUD stubs. They
  # exist so `respond_to?` is true — a wrapper regression back to
  # "forward anything the client answers" then reaches them and fails the
  # suite audibly for EVERY method, not just call_rpc_raw.
  %i[connect disconnect authenticate signon_setup authenticated? duz
     call_rpc_global_array create_context set_authenticated].each do |name|
    define_method(name) do |*_args, **_options|
      raise "GATE: #{name} reached the fake through a wrapper that should refuse to forward it"
    end
  end

  def connected? = true
  def hostname = "fake-broker.test"
  def received_calls = @calls
  def calls_for(rpc) = @calls.select { |c| c[:rpc] == rpc }
  def last_call = @calls.last
end

# Install a FakeBroker as RpmsRpc.client for the duration of the block,
# restoring the stand-in's connection afterward.
module BrokerStubbing
  def use_broker(fake)
    original = RpmsRpc.configuration.client
    RpmsRpc.configure { |c| c.client = fake }
    yield fake
  ensure
    RpmsRpc.configure { |c| c.client = original }
  end
end

# Shared auth helper for integration tests.
module SmartAuthTestHelper
  def setup_smart_auth(scopes: "system/*.read")
    @oauth_app = Doorkeeper::Application.create!(
      name: "test", redirect_uri: "https://example.test/callback",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: @oauth_app, scopes: scopes, expires_in: 3600
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def teardown_smart_auth
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.delete_all
  end
end

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = "#{File.expand_path('fixtures', __dir__)}/files"
  ActiveSupport::TestCase.fixtures :all
end

ActiveSupport::TestCase.include GlobalStoreIsolation
ActiveSupport::TestCase.include StubHelpers
ActiveSupport::TestCase.include SchedulingSetupStubs
