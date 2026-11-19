# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/authentication"

# A SMART Backend Services (system/) token reads RPMS through a broker session
# signed on as its client application's own service account (ADR 0011 section
# 6, ADR 0013 decision 4: one account per backend client, #996), keyed to the
# client application and never to a person: every live token of one
# application shares one session, and no application rides another's account. A request that gets no such session runs
# with no RPMS client at all, so a read that reaches RPMS answers 503 as before
# and one that never touches RPMS answers as it always did; a user/ or patient/
# token never rides the service account.
#
# The process is set up as a server is: no shared client, and a pool whose
# factory builds a fresh mock broker per sign-on. Each mock carries the suite's
# baseline seeds and two synthetic service-account users (client A's, DUZ 4242,
# and client B's, DUZ 9002), and records for every RPC the DUZ it held at the
# moment of the call.
class BackendServiceAccountRpmsTest < ActionDispatch::IntegrationTest
  SERVICE_DUZ = 4242
  ACCESS_CODE = "SVCACCT1"
  VERIFY_CODE = "SVCACCT1!!"
  # Client B's own account: another RPMS user, with its own codes.
  SERVICE_DUZ_B = 9002
  ACCESS_CODE_B = "SVCB1"
  VERIFY_CODE_B = "SVCB1!!"
  CLIENT_ID_A = "synthetic-backend-a"
  CLIENT_ID_B = "synthetic-backend-b"
  ENV_KEYS = %w[RPMS_SERVICE_ACCESS_CODE RPMS_SERVICE_VERIFY_CODE RPMS_SERVICE_CLIENT_ID].freeze
  # Sent before anyone is signed on, so they carry no DUZ by construction.
  # XUS GET USER INFO is the gem's own read-back inside authenticate, sent before it returns.
  SIGNON_RPCS = [ "XUS SIGNON SETUP", "XUS AV CODE", "XUS GET USER INFO" ].freeze
  NO_CONNECTION = "This request has no RPMS connection of its own."
  SYSTEM_SCOPES = "system/Patient.rs system/ServiceRequest.rs"
  CLINICIAN_DUZ = 208
  READS = [
    [ "Patient", "/lakeraven-ehr/Patient/1" ],
    [ "ServiceRequest", "/lakeraven-ehr/ServiceRequest?patient=1" ]
  ].freeze

  # The mock broker, as one connection of the pool. Like a real connection it
  # is connected from its sign-on (by #connect, #authenticate, or the first RPC
  # sent on it) until #disconnect or the broker drops it (#drop!), and records
  # each RPC with the DUZ it ran under.
  class RecordingClient < RpmsRpc::MockClient
    attr_reader :rpcs, :disconnected, :av_codes
    # Set to an exception class to have #disconnect raise it.
    attr_accessor :disconnect_error

    def initialize
      super
      @rpcs = []
      @av_codes = []
      @hooks = {}
      @connected = false
      @disconnected = false
      @dropped = false
    end

    def connect(*) = (@connected = true)
    def connected? = @connected && !@disconnected && !@dropped

    def disconnect
      @disconnected = true
      raise disconnect_error, "synthetic disconnect failure" if disconnect_error
    end

    # The broker went away under us: no longer connected, never logged off.
    def drop! = (@dropped = true)

    # Run the block once, when the client is next sent rpc_name.
    def on_rpc(rpc_name, &hook) = (@hooks[rpc_name] = hook)

    # Client#authenticate's shape, for a sign-on made on the client itself.
    def authenticate(access_code = nil, verify_code = nil, **)
      result = RpmsRpc.with_client(self) do
        RpmsRpc::Authentication.authenticate(access_code: access_code, verify_code: verify_code)
      end
      raise RpmsRpc::Client::AuthenticationError, "Authentication failed" unless result[:success]

      { success: true, duz: result[:duz], user: result[:name] }
    end

    def call_rpc(rpc_name, *params)
      record(rpc_name, params)
      super
    end

    def call_rpc_lines(rpc_name, *params)
      record(rpc_name, params)
      super
    end

    def call_rpc_global_array(rpc_name, *params)
      record(rpc_name, params)
      super
    end

    # The RPCs made once the sign-on exchange itself was over.
    def rpcs_after_signon = rpcs.reject { |rpc| SIGNON_RPCS.include?(rpc[:rpc]) }

    # How many sign-ons (XUS AV CODE) were sent on this connection.
    def signons = rpcs.count { |rpc| rpc[:rpc] == "XUS AV CODE" }

    private

    # The "ACCESS;VERIFY" pair the broker would decrypt from the parameter.
    def decoded_av_code(param)
      RpmsRpc::XwbCipher.framed?(param) ? RpmsRpc::XwbCipher.decrypt(param.to_s) : param.to_s
    rescue StandardError
      param.to_s
    end

    def record(rpc_name, params = [])
      @connected = true # an RPC only travels on an open connection
      @rpcs << { rpc: rpc_name, duz: duz&.to_s }
      @av_codes << decoded_av_code(params.first) if rpc_name == "XUS AV CODE"
      @hooks.delete(rpc_name)&.call
    end
  end

  setup do
    skip "needs the mock broker" if LIVE_RPMS

    @saved_env = ENV_KEYS.to_h { |key| [ key, ENV.key?(key) ? ENV[key] : :missing ] }
    ENV_KEYS.each { |key| ENV.delete(key) }

    @clients = []
    @prepare_client = nil
    RpmsRpc.reset! # no shared client in a pooled process
    configure_pool(max_sessions: 4)
    @client_app = backend_app("backend-client-a", "synthetic-org-a", uid: CLIENT_ID_A)
    @token = token_for(@client_app)
  end

  teardown do
    @restore_touch&.call
    @restore_credentials&.call
    (@saved_env || {}).each { |key, value| value == :missing ? ENV.delete(key) : ENV[key] = value }
    # Later tests get the suite's shared mock back, whatever they include.
    Lakeraven::EHR::RpmsSessions.reset!
    RpmsRpc.mock!(&BASELINE_MOCK_SEEDS) unless LIVE_RPMS
  end

  # The ENV pair, which belongs to the one client RPMS_SERVICE_CLIENT_ID names:
  # the test's application A unless another is given.
  def configure_service_account(access: ACCESS_CODE, verify: VERIFY_CODE, client: @client_app)
    ENV["RPMS_SERVICE_ACCESS_CODE"] = access if access
    ENV["RPMS_SERVICE_VERIFY_CODE"] = verify if verify
    ENV["RPMS_SERVICE_CLIENT_ID"] = client.uid if client
  end

  # Rails.application.credentials with the given rpms subtree; everything else
  # is the real object's. The real one holds symbol keys; a client_id may be
  # dug as a symbol or a string.
  class RpmsCredentials < SimpleDelegator
    def initialize(real, rpms)
      super(real)
      @tree = { rpms: rpms }.with_indifferent_access
    end

    def dig(*keys) = keys.first.to_s == "rpms" ? @tree.dig(*keys) : __getobj__.dig(*keys)
    def rpms = @tree[:rpms]
    def [](key) = key.to_s == "rpms" ? @tree[:rpms] : __getobj__[key]
  end

  # Give each application its own account in the host's credentials
  # (rpms.service_accounts.<client_id>), for the rest of the test. accounts maps
  # an application to its [access_code, verify_code]; extra is merged into the
  # rpms subtree beside it.
  def configure_credentials_accounts(accounts, extra: {})
    @restore_credentials&.call
    entries = accounts.to_h { |app, (access, verify)| [ app.uid, { access_code: access, verify_code: verify } ] }
    fake = RpmsCredentials.new(Rails.application.credentials, { service_accounts: entries }.merge(extra))
    restore = install_singleton_stub(Rails.application, :credentials, fake)
    @restore_credentials = lambda do
      restore.call
      @restore_credentials = nil
    end
  end

  # Client application B, another backend client of the deployment.
  def client_app_b = @client_app_b ||= backend_app("backend-client-b", "synthetic-org-b", uid: CLIENT_ID_B)

  # The pool as a server configures it; again in a test that needs another size.
  def configure_pool(max_sessions:)
    Lakeraven::EHR::RpmsSessions.reset!
    Lakeraven::EHR::RpmsSessions.configure!(factory: -> { build_client }, max_sessions: max_sessions, keeper: false)
  end

  # One fresh connection for a service-account sign-on, as the factory makes it.
  def build_client
    seeded_client.tap do |client|
      client.seed_user(SERVICE_DUZ, credentials: "#{ACCESS_CODE};#{VERIFY_CODE}", name: "SERVICE,ACCOUNT", role: "user")
      client.seed_user(SERVICE_DUZ_B, credentials: "#{ACCESS_CODE_B};#{VERIFY_CODE_B}", name: "SERVICE,ACCOUNTB", role: "user")
      @prepare_client&.call(client)
      @clients << client
    end
  end

  def seeded_client = RecordingClient.new.tap { |client| BASELINE_MOCK_SEEDS.call(client) }

  # A signed-in clinician's own connection, held in the pool under their
  # token's key the way sign-in adopts it. Not one of @clients: the factory
  # did not build it for the service account.
  def adopt_clinician(duz = CLINICIAN_DUZ)
    client = seeded_client
    client.seed_user(duz, credentials: "CLIN#{duz};CLIN#{duz}!!", name: "CLINICIAN,SYNTHETIC", role: "provider")
    client.authenticate("CLIN#{duz}", "CLIN#{duz}!!")
    key = Lakeraven::EHR::RpmsSessions.key_for(person_token("user", duz))
    Lakeraven::EHR::RpmsSessions.adopt(key, client)
    [ key, client ]
  end

  def backend_app(name, organization_id, uid: nil)
    Doorkeeper::Application.create!(
      { name: name, redirect_uri: "https://example.test/callback",
        scopes: SYSTEM_SCOPES, confidential: true, organization_id: organization_id, uid: uid }.compact
    )
  end

  def token_for(app, scopes: SYSTEM_SCOPES, expires_in: 300)
    Doorkeeper::AccessToken.create!(application: app, scopes: scopes, expires_in: expires_in)
  end

  def backend_token(name, organization_id) = token_for(backend_app(name, organization_id))

  # A header token of an ordinary (non-launch, non-browser) application.
  def person_token(context, resource_owner_id)
    scopes = "#{context}/Patient.rs #{context}/ServiceRequest.rs"
    app = Doorkeeper::Application.create!(
      name: "#{context}-client", redirect_uri: "https://example.test/callback",
      scopes: scopes, confidential: true
    )
    Doorkeeper::AccessToken.create!(application: app, scopes: scopes, expires_in: 300,
                                    resource_owner_id: resource_owner_id)
  end

  def read(path, token = @token)
    get path, headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def service_key(token = @token) = Lakeraven::EHR::RpmsSessions.service_key_for(token)

  def assert_no_rpms_connection(label)
    assert_equal 503, response.status, "#{label}: expected the 503 of a request with no RPMS connection"
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "transient", body["issue"][0]["code"]
    assert_equal NO_CONNECTION, body["issue"][0]["diagnostics"]
  end

  def assert_no_client_built
    assert_empty @clients, "no RPMS connection was opened"
  end

  def assert_read_ok(label = "read")
    assert_equal 200, response.status, "#{label}: #{response.body[0, 300]}"
  end

  def held?(key) = Lakeraven::EHR::RpmsSessions.held?(key)

  # One real keeper pass. The pool has no public way to run one.
  def keeper_tick = Lakeraven::EHR::RpmsSessions.instance_variable_get(:@pool).keep_alive_tick

  # Run the block once, right after RpmsSessions.touch has returned truthy for
  # key: the window between a lease's touch and its checkout. touch is wrapped
  # on the singleton class and put back by @restore_touch (teardown runs it too).
  def after_service_touch(key, &hook)
    sessions = Lakeraven::EHR::RpmsSessions
    original = sessions.method(:touch).unbind
    @restore_touch = singleton_method_restore(sessions, :touch)
    sessions.define_singleton_method(:touch) do |touched, **options|
      original.bind_call(self, touched, **options).tap do |kept|
        next unless kept && touched == key && hook

        run = hook
        hook = nil
        run.call
      end
    end
  end

  # Rails.application.credentials whose every read raises, as an undecryptable
  # or mis-shaped credentials file does. Anything else is the real object's.
  class UnreadableCredentials < SimpleDelegator
    def initialize(real, error)
      super(real)
      @error = error
    end

    def dig(*) = raise(@error, "synthetic unreadable credentials")
  end

  def with_unreadable_credentials(error, &block)
    with_stub(Rails.application, :credentials, UnreadableCredentials.new(Rails.application.credentials, error), &block)
  end

  READS.each do |resource, path|
    # A.
    test "a system/ token reads #{resource} on the service account's connection" do
      configure_service_account

      read path

      assert_equal 200, response.status, response.body[0, 300]
      assert_equal "application/fhir+json", response.media_type
      assert_kind_of Hash, JSON.parse(response.body)
      rpcs = @clients.flat_map(&:rpcs_after_signon)
      assert_predicate rpcs, :any?, "the read reached RPMS"
      assert_equal [ SERVICE_DUZ.to_s ], rpcs.map { |rpc| rpc[:duz].to_s }.uniq,
                   "every RPC ran as the service account: #{rpcs.inspect}"
      assert_nil RpmsRpc.configuration.client, "the process still holds no shared client"
      assert Lakeraven::EHR::RpmsSessions.held?(service_key), "the service-account lease is held for the token"
    end

    # B.
    test "a system/ token reading #{resource} answers 503 when no service account is configured" do
      read path

      assert_no_rpms_connection(resource)
      assert_no_client_built
    end

    # C.
    test "a system/ token reading #{resource} answers 503 when only the access code is configured" do
      configure_service_account(verify: nil)

      read path

      assert_no_rpms_connection(resource)
      assert_no_client_built
    end

    # D.
    test "a user/ token reading #{resource} never rides the service account" do
      configure_service_account

      read path, person_token("user", 9101) # a synthetic DUZ

      assert_no_rpms_connection(resource)
      assert_no_client_built
    end

    # E. Bound to patient 1, so the compartment check passes and the read
    # reaches for RPMS.
    test "a patient/ token reading #{resource} never rides the service account" do
      configure_service_account

      read path, person_token("patient", 1)

      assert_no_rpms_connection(resource)
      assert_no_client_built
    end
  end

  # F.
  test "the lease is shared by an application's tokens and released when any of them is revoked" do
    configure_service_account
    second = token_for(@client_app)

    2.times do
      read "/lakeraven-ehr/Patient/1"
      assert_read_ok
    end
    read "/lakeraven-ehr/Patient/1", second
    assert_read_ok "the application's second token"
    assert_equal 1, @clients.size, "one sign-on serves every read of the application"
    key = service_key
    assert held?(key)

    @token.revoke

    refute held?(key), "revocation releases the application's service-account lease"
    assert @clients[0].disconnected, "RPMS logs the service account's session off"
    read "/lakeraven-ehr/Patient/1"
    assert_equal 401, response.status
    assert_equal 1, @clients.size, "a revoked token opens no connection"

    used = @clients[0].rpcs.size
    read "/lakeraven-ehr/Patient/1", second
    assert_read_ok "the application's live token, after the other was revoked"
    assert_equal 2, @clients.size, "the next valid token signs on afresh"
    assert_equal used, @clients[0].rpcs.size, "the logged-off connection is not used again"
    assert_equal SERVICE_DUZ.to_s, @clients[1].duz.to_s
    assert held?(key)
  end

  test "a fresh token of the application reads on a new connection after an earlier one was revoked" do
    configure_service_account
    read "/lakeraven-ehr/Patient/1"
    assert_read_ok
    @token.revoke

    read "/lakeraven-ehr/Patient/1", token_for(@client_app)

    assert_read_ok "fresh token"
    assert_equal 2, @clients.size
    assert @clients[0].disconnected
    refute @clients[1].disconnected
    assert_equal [ SERVICE_DUZ.to_s ], @clients[1].rpcs_after_signon.map { |rpc| rpc[:duz] }.uniq
  end

  # G.
  test "a refused service-account sign-on fails closed" do
    configure_service_account(access: "WRONG1", verify: "WRONG1!!")

    read "/lakeraven-ehr/Patient/1"

    assert_no_rpms_connection("refused sign-on")
    assert_equal 1, @clients.size, "one sign-on was attempted"
    assert @clients.all?(&:disconnected), "a connection that signed no one on is closed"
    refute held?(service_key), "nothing is held for the application"
  end

  test "a sign-on RPMS answers with a verify code that must change is refused" do
    configure_service_account
    @prepare_client = lambda do |client|
      client.seed_lines(:av_code, "#{ACCESS_CODE};#{VERIFY_CODE}",
                        duz: SERVICE_DUZ, error_code: 0, verify_needs_change: 1,
                        message: "Welcome SERVICE,ACCOUNT", post_signon_message_count: 0)
    end

    read "/lakeraven-ehr/Patient/1"

    assert_no_rpms_connection("verify code must change")
    assert_equal 1, @clients.size
    assert @clients[0].disconnected, "the connection is closed"
    assert_empty @clients[0].rpcs_after_signon, "nothing was read on it"
    refute held?(service_key), "nothing is held for the application"
  end

  test "a disconnect that raises during a refused sign-on still answers 503" do
    configure_service_account(access: "WRONG1", verify: "WRONG1!!")
    @prepare_client = ->(client) { client.disconnect_error = IOError }

    assert_nothing_raised { read "/lakeraven-ehr/Patient/1" }

    assert_no_rpms_connection("refused sign-on, disconnect raising")
    assert_equal 1, @clients.size
    assert @clients[0].disconnected, "the disconnect was attempted"
    refute held?(service_key)
  end

  # Back-off: a refused sign-on is not retried on every request. (It is the
  # refused client's own: see "a refused sign-on backs off its own client only".)
  test "after a refused sign-on no new sign-on is attempted until the back-off has passed" do
    configure_service_account(access: "WRONG1", verify: "WRONG1!!")

    2.times do
      read "/lakeraven-ehr/Patient/1"
      assert_no_rpms_connection("refused sign-on")
    end
    assert_equal 1, @clients.size, "the second request inside the back-off signs nobody on"
    assert_equal 30, Lakeraven::EHR::RpmsSessions::SERVICE_SIGNON_BACKOFF

    read "/lakeraven-ehr/Patient/1", token_for(client_app_b)
    assert_no_rpms_connection("another application, with no account of its own")
    assert_equal 1, @clients.size, "an application with no account never sends the refused application's codes"

    travel (Lakeraven::EHR::RpmsSessions::SERVICE_SIGNON_BACKOFF + 1).seconds
    read "/lakeraven-ehr/Patient/1", token_for(@client_app) # the first token may have expired by now
    assert_no_rpms_connection("refused again")
    assert_equal 2, @clients.size, "after the back-off a sign-on is tried again"
    assert @clients.all?(&:disconnected)
  end

  # The pool is rebuilt per test (and per boot): a back-off does not outlive it.
  test "a reconfigured pool starts with no back-off" do
    configure_service_account(access: "WRONG1", verify: "WRONG1!!")
    read "/lakeraven-ehr/Patient/1"
    assert_no_rpms_connection("refused sign-on")

    configure_pool(max_sessions: 4)
    configure_service_account
    read "/lakeraven-ehr/Patient/1"

    assert_read_ok "after the pool was reconfigured"
    assert_equal 2, @clients.size
  end

  # H.
  test "the lease is keyed to the client application, never to a person or a token" do
    configure_service_account
    configure_credentials_accounts({ client_app_b => [ ACCESS_CODE_B, VERIFY_CODE_B ] })
    other = token_for(client_app_b)
    sibling = token_for(@client_app)

    key = service_key
    refute_equal Lakeraven::EHR::RpmsSessions.key_for(@token), key
    assert_equal "system-app-#{@token.application_id}", key
    assert_equal key, service_key(sibling), "an application's tokens share its key"
    refute_equal key, service_key(other)

    read "/lakeraven-ehr/Patient/1"
    assert_read_ok
    read "/lakeraven-ehr/Patient/1", other
    assert_read_ok "another application"

    assert_equal 2, @clients.size, "each application signs on for itself"
    assert_equal [ SERVICE_DUZ.to_s, SERVICE_DUZ_B.to_s ], @clients.map { |client| client.duz.to_s },
                 "each on its own account"
    assert held?(key)
    assert held?(service_key(other))
  end

  test "two tokens of the same application read on one connection" do
    configure_service_account
    sibling = token_for(@client_app)

    [ @token, sibling ].each do |token|
      read "/lakeraven-ehr/Patient/1", token
      assert_read_ok
    end

    assert_equal 1, @clients.size, "one sign-on for the application"
    assert_equal 1, @clients[0].rpcs.count { |rpc| rpc[:rpc] == "XUS AV CODE" }
    rpcs = @clients[0].rpcs_after_signon
    assert_equal [ SERVICE_DUZ.to_s ], rpcs.map { |rpc| rpc[:duz] }.uniq, "both read as the service account"
    assert held?(service_key)
    assert_equal service_key, service_key(sibling)
  end

  # Capacity. Each lease is an M job on the RPMS host, and the pool is the
  # clinicians' too: one application takes one slot however many tokens it has.
  test "one application's tokens cannot fill the pool" do
    configure_pool(max_sessions: 2)
    configure_service_account
    clinician_key, = adopt_clinician

    5.times do |n|
      read "/lakeraven-ehr/Patient/1", token_for(@client_app)
      assert_read_ok "token #{n + 1}"
    end

    assert_equal 1, @clients.size, "one service-account connection for the application"
    assert held?(clinician_key), "the clinician keeps their connection"
    assert held?(service_key)
    # Both slots are taken, by exactly those two: there is no third.
    assert_raises(RpmsRpc::SessionPool::PoolExhaustedError) do
      Lakeraven::EHR::RpmsSessions.adopt("token-synthetic-third", seeded_client)
    end
  end

  test "a full pool signs nobody on" do
    configure_pool(max_sessions: 1)
    configure_service_account
    clinician_key, clinician = adopt_clinician
    used = clinician.rpcs.size

    read "/lakeraven-ehr/Patient/1"

    assert_no_rpms_connection("full pool")
    assert_no_client_built
    refute held?(service_key)
    assert held?(clinician_key), "no signed-in user is evicted to make room"
    assert_equal used, clinician.rpcs.size, "and their connection served nothing"
  end

  # ADR 0011 section 7: two identities in one process, each on its own connection.
  test "service-account reads never run on a signed-in clinician's connection" do
    configure_service_account
    clinician_key, clinician = adopt_clinician
    assert_equal CLINICIAN_DUZ.to_s, clinician.duz.to_s
    used = clinician.rpcs.size

    READS.each do |resource, path|
      read path
      assert_read_ok resource
    end

    assert_equal 1, @clients.size
    rpcs = @clients[0].rpcs_after_signon
    assert_predicate rpcs, :any?
    assert_equal [ SERVICE_DUZ.to_s ], rpcs.map { |rpc| rpc[:duz] }.uniq, "every RPC ran as the service account"
    assert_equal used, clinician.rpcs.size, "the clinician's connection carried none of it"
    assert_equal CLINICIAN_DUZ.to_s, clinician.duz.to_s
    assert held?(clinician_key)
    refute_equal clinician_key, service_key
  end

  # A request that gets no lease runs with no RPMS client: an endpoint that
  # never touches RPMS answers as it does on main. GET Measure makes no RPC.
  NO_LEASE = {
    "no service account is configured" => ->(_test) { },
    "the service-account sign-on is refused" => ->(test) { test.configure_service_account(access: "WRONG1", verify: "WRONG1!!") },
    "the pool is full" => lambda { |test|
      test.configure_pool(max_sessions: 1)
      test.configure_service_account
      test.adopt_clinician
    }
  }.freeze

  NO_LEASE.each do |condition, arrange|
    test "a read that never touches RPMS still answers 200 when #{condition}" do
      arrange.call(self)
      token = token_for(@client_app, scopes: "#{SYSTEM_SCOPES} system/Measure.rs")

      read "/lakeraven-ehr/Measure", token

      assert_read_ok "Measure search"
      assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
      assert_empty @clients.reject(&:disconnected), "no RPMS connection is left open"
      assert_empty @clients.flat_map(&:rpcs_after_signon), "nothing was read from RPMS"
      refute held?(service_key(token))
    end
  end

  test "a read that never touches RPMS opens no connection when no service account is configured" do
    read "/lakeraven-ehr/Measure", token_for(@client_app, scopes: "#{SYSTEM_SCOPES} system/Measure.rs")

    assert_read_ok "Measure search"
    assert_no_client_built
  end

  # Credentials the host cannot read are no credentials (ServiceAccount.codes).
  [ TypeError, ActiveSupport::MessageEncryptor::InvalidMessage ].each do |error|
    test "credentials that raise #{error.name} and no ENV pair answer 503" do
      with_unreadable_credentials(error) do
        assert_nothing_raised { read "/lakeraven-ehr/Patient/1" }
      end

      assert_no_rpms_connection("unreadable credentials")
      assert_no_client_built
    end
  end

  test "credentials that raise fall through to the ENV pair" do
    configure_service_account

    with_unreadable_credentials(TypeError) { read "/lakeraven-ehr/Patient/1" }

    assert_read_ok
    assert_equal [ SERVICE_DUZ.to_s ], @clients.flat_map(&:rpcs_after_signon).map { |rpc| rpc[:duz] }.uniq
  end

  # The revocation is another request's, committed while this one signs on:
  # the token row is revoked and the release that follows the commit
  # (ServiceAccountLeaseRelease) finds nothing held yet. A revoke made on this
  # request's own database connection would not model it: its after_commit
  # waits for the request's audit transaction, after the action.
  test "a token revoked while its first request is signing on leaves nothing held" do
    configure_service_account
    token_id = @token.id
    @prepare_client = lambda do |client|
      client.on_rpc("XUS AV CODE") do
        revoked = Doorkeeper::AccessToken.find(token_id)
        revoked.update_columns(revoked_at: Time.current)
        Lakeraven::EHR::RpmsSessions.release_service_account(revoked)
      end
    end

    read "/lakeraven-ehr/Patient/1" # 200 or 503: the token was good when it arrived

    assert_predicate @token.reload, :revoked?
    assert_equal 1, @clients.size
    refute held?(service_key), "no lease outlives the revocation"
    assert @clients[0].disconnected, "RPMS logs the session off"
  end

  test "a lease whose connection dropped is released, and the next read signs on afresh" do
    configure_service_account
    read "/lakeraven-ehr/Patient/1"
    assert_read_ok
    dropped = @clients[0]
    used = dropped.rpcs.size

    dropped.drop!
    read "/lakeraven-ehr/Patient/1"

    assert_read_ok "after the connection dropped"
    assert_equal 2, @clients.size, "a second sign-on"
    assert_equal used, dropped.rpcs.size, "the dropped connection is not used"
    assert dropped.disconnected, "and is released"
    assert_predicate @clients[1].rpcs_after_signon, :any?
    assert_equal [ SERVICE_DUZ.to_s ], @clients[1].rpcs_after_signon.map { |rpc| rpc[:duz] }.uniq
    assert held?(service_key)
  end

  test "a dropped connection whose fresh sign-on is refused answers 503" do
    configure_service_account
    read "/lakeraven-ehr/Patient/1"
    assert_read_ok
    dropped = @clients[0]
    used = dropped.rpcs.size

    dropped.drop!
    configure_service_account(access: "WRONG1", verify: "WRONG1!!")
    read "/lakeraven-ehr/Patient/1"

    assert_no_rpms_connection("dropped connection, refused sign-on")
    assert_equal used, dropped.rpcs.size, "the dropped connection is not used"
    assert_equal 2, @clients.size
    assert @clients.all?(&:disconnected)
    refute held?(service_key)
  end

  test "a lease that is no longer the service account's is released, not used" do
    configure_service_account
    read "/lakeraven-ehr/Patient/1"
    assert_read_ok
    client = @clients[0]
    used = client.rpcs.size

    client.set_authenticated(CLINICIAN_DUZ.to_s) # the connection is someone else's now
    read "/lakeraven-ehr/Patient/1"

    assert_no_rpms_connection("identity mismatch")
    assert_equal used, client.rpcs.size, "nothing ran as the other identity"
    assert client.disconnected
    refute held?(service_key)
  end

  # The lease can end between the touch that keeps it and the checkout: a
  # sibling token of the application is revoked (or the keeper drops it), and
  # a clinician signing in takes the freed slot of a full pool. The request
  # then has no RPMS connection; it does not fail on the pool's capacity.
  test "a lease released and its slot taken between touch and checkout answers 503" do
    configure_pool(max_sessions: 1)
    configure_service_account
    read "/lakeraven-ehr/Patient/1"
    assert_read_ok "the read that takes the lease"
    key = service_key
    assert held?(key)
    service_rpcs = @clients[0].rpcs.size

    clinician = seeded_client
    clinician.seed_user(CLINICIAN_DUZ, credentials: "CLIN1;CLIN1!!", name: "CLINICIAN,SYNTHETIC", role: "provider")
    clinician.authenticate("CLIN1", "CLIN1!!")
    clinician_key = Lakeraven::EHR::RpmsSessions.key_for(person_token("user", CLINICIAN_DUZ))
    used = clinician.rpcs.size
    token = @token
    injected = 0

    after_service_touch(key) do
      injected += 1
      Lakeraven::EHR::RpmsSessions.release_service_account(token)
      Lakeraven::EHR::RpmsSessions.adopt(clinician_key, clinician)
    end
    begin
      assert_nothing_raised { read "/lakeraven-ehr/Patient/1" }
    ensure
      @restore_touch&.call
    end

    assert_equal 1, injected, "the lease was released right after its touch, once"
    assert_no_rpms_connection("lease released and the pool filled before checkout")
    assert_equal used, clinician.rpcs.size, "the clinician's connection received no RPC"
    assert_empty clinician.rpcs_after_signon
    assert_equal CLINICIAN_DUZ.to_s, clinician.duz.to_s
    refute clinician.disconnected
    assert held?(clinician_key), "the clinician keeps their connection"
    refute held?(key), "the service-account lease stays released"
    assert_equal 1, @clients.size, "no second service-account sign-on"
    assert_equal service_rpcs, @clients[0].rpcs.size, "the released connection served nothing more"
  end

  # A factory that cannot make a connection (a mis-shaped config/rpms.yml, say)
  # is a failed sign-on like any other: 503, and the back-off.
  test "a connection factory that raises answers 503 and is not called again inside the back-off" do
    built = 0
    Lakeraven::EHR::RpmsSessions.reset!
    Lakeraven::EHR::RpmsSessions.configure!(
      factory: lambda {
        built += 1
        raise ArgumentError, "synthetic factory failure"
      },
      max_sessions: 4, keeper: false
    )
    configure_service_account

    assert_nothing_raised { read "/lakeraven-ehr/Patient/1" }

    assert_no_rpms_connection("factory raising")
    assert_equal 1, built, "the factory was asked for one connection"
    refute held?(service_key)

    assert_nothing_raised { read "/lakeraven-ehr/Patient/1" }

    assert_no_rpms_connection("factory raising, inside the back-off")
    assert_equal 1, built, "the second read inside the back-off builds nothing"
    refute held?(service_key)
  end

  # Strict: every scope on the token is a system/ scope, or it is not a
  # Backend Services token and never rides the service account.
  [ "openid", "launch/patient", "offline_access", "user/Patient.rs" ].each do |extra|
    test "a token carrying #{extra} beside its system/ scopes never rides the service account" do
      configure_service_account

      read "/lakeraven-ehr/Patient/1", token_for(@client_app, scopes: "system/Patient.rs #{extra}")

      assert_no_rpms_connection("system/Patient.rs #{extra}")
      assert_no_client_built
    end
  end

  # I.
  test "an expired token answers 401 and opens no new connection" do
    configure_service_account
    read "/lakeraven-ehr/Patient/1"
    assert_read_ok
    assert_equal 1, @clients.size

    travel 301.seconds

    read "/lakeraven-ehr/Patient/1"
    assert_equal 401, response.status
    assert_equal 1, @clients.size, "an expired token signs nobody on"
  end

  # The pool's deadlines run on the monotonic clock, which travel does not
  # move: a token of two seconds (one with less than a whole second left gets
  # no lease at all), and a real wait.
  test "the keeper keeps a live lease and ends it once its token has expired" do
    configure_service_account
    token = token_for(@client_app, expires_in: 2)
    read "/lakeraven-ehr/Patient/1", token
    assert_read_ok
    key = service_key(token)

    keeper_tick
    assert held?(key), "a connected lease inside its token's lifetime survives a keeper pass"
    refute @clients[0].disconnected

    sleep 2.2
    keeper_tick

    refute held?(key), "the lease does not outlive its token"
    assert @clients[0].disconnected, "RPMS logs the service account's session off"
    read "/lakeraven-ehr/Patient/1", token
    assert_equal 401, response.status
    assert_equal 1, @clients.size
  end

  # ---------------------------------------------------------------------------
  # One RPMS account per backend client (ADR 0013 decision 4). The codes are
  # looked up for the token's client application, by its client_id (uid):
  # credentials at rpms.service_accounts.<client_id>, else the ENV pair of the
  # one client RPMS_SERVICE_CLIENT_ID names. No deployment-wide account.
  # ---------------------------------------------------------------------------

  def service_duzes(client) = client.rpcs_after_signon.map { |rpc| rpc[:duz] }.uniq

  # Every call of RpmsRpc::SessionPool#touch on the configured pool, with the
  # wall-clock time (the clock token lifetimes are measured on) of the call.
  def spy_on_pool_touch
    pool = Lakeraven::EHR::RpmsSessions.instance_variable_get(:@pool)
    touches = []
    original = pool.method(:touch)
    pool.define_singleton_method(:touch) do |key, idle_for:|
      touches << { key: key, idle_for: idle_for, at: Time.current }
      original.call(key, idle_for: idle_for)
    end
    touches
  end

  # The broker takes this long to answer the service account's sign-on.
  def slow_sign_on(duration)
    @prepare_client = ->(client) { client.on_rpc("XUS AV CODE") { travel duration } }
  end

  # 1e. A's account is the ENV pair's, B's is in the credentials.
  test "two backend clients each read as their own service account" do
    configure_service_account
    configure_credentials_accounts({ client_app_b => [ ACCESS_CODE_B, VERIFY_CODE_B ] })
    token_b = token_for(client_app_b)

    read "/lakeraven-ehr/Patient/1"
    assert_read_ok "client A"
    read "/lakeraven-ehr/Patient/1", token_b
    assert_read_ok "client B"

    assert_equal 2, @clients.size, "each application signs on for itself"
    of_a, of_b = @clients
    assert_equal SERVICE_DUZ.to_s, of_a.duz.to_s
    assert_equal SERVICE_DUZ_B.to_s, of_b.duz.to_s, "B signs on as B's account, not A's"
    assert_equal [ SERVICE_DUZ.to_s ], service_duzes(of_a), "every RPC of A's request ran as A's DUZ"
    assert_equal [ SERVICE_DUZ_B.to_s ], service_duzes(of_b), "every RPC of B's request ran as B's DUZ"
    assert_equal [ "#{ACCESS_CODE};#{VERIFY_CODE}" ], of_a.av_codes
    assert_equal [ "#{ACCESS_CODE_B};#{VERIFY_CODE_B}" ], of_b.av_codes, "A's codes are never sent for B"
    assert held?(service_key)
    assert held?(service_key(token_b))
  end

  # 1e. Both accounts in the credentials, B first: neither order nor source
  # hands one client the other's account.
  test "two backend clients with credentials entries each read as their own service account" do
    configure_credentials_accounts({ @client_app => [ ACCESS_CODE, VERIFY_CODE ],
                                   client_app_b => [ ACCESS_CODE_B, VERIFY_CODE_B ] })
    token_b = token_for(client_app_b)

    read "/lakeraven-ehr/Patient/1", token_b
    assert_read_ok "client B"
    read "/lakeraven-ehr/Patient/1"
    assert_read_ok "client A"
    read "/lakeraven-ehr/Patient/1", token_b
    assert_read_ok "client B again"

    assert_equal 2, @clients.size, "one sign-on per application"
    of_b, of_a = @clients
    assert_equal [ SERVICE_DUZ_B.to_s ], service_duzes(of_b), "every RPC of B's requests ran as B's DUZ"
    assert_equal [ SERVICE_DUZ.to_s ], service_duzes(of_a), "every RPC of A's request ran as A's DUZ"
    assert_equal [ "#{ACCESS_CODE_B};#{VERIFY_CODE_B}" ], of_b.av_codes
    assert_equal [ "#{ACCESS_CODE};#{VERIFY_CODE}" ], of_a.av_codes
  end

  # 1f.
  test "a backend client with no account of its own answers 503 and sends no RPC while another client's account is leased" do
    configure_service_account
    read "/lakeraven-ehr/Patient/1"
    assert_read_ok "client A, which has an account"
    assert held?(service_key)
    used = @clients[0].rpcs.size
    token_b = token_for(client_app_b)

    READS.each do |resource, path|
      read path, token_b

      assert_no_rpms_connection("client B reading #{resource}")
    end
    assert_equal 1, @clients.size, "no connection was opened for B, not even for a sign-on"
    assert_equal used, @clients[0].rpcs.size, "and A's connection carried nothing for B"
    assert_equal 1, @clients[0].signons
    refute held?(service_key(token_b))
    assert held?(service_key), "A keeps its lease"
  end

  # 1f, with A's account in the credentials.
  test "a backend client with no credentials entry answers 503 though another client has one" do
    configure_credentials_accounts({ @client_app => [ ACCESS_CODE, VERIFY_CODE ] })
    token_b = token_for(client_app_b)

    read "/lakeraven-ehr/Patient/1", token_b

    assert_no_rpms_connection("client B, with no entry")
    assert_no_client_built
    refute held?(service_key(token_b))

    read "/lakeraven-ehr/Patient/1"
    assert_read_ok "client A, on its own entry"
    assert_equal [ SERVICE_DUZ.to_s ], service_duzes(@clients[0])
  end

  # 1b. The ENV pair is one client's: unnamed, it is nobody's.
  test "the ENV pair with no RPMS_SERVICE_CLIENT_ID is no client's account" do
    configure_service_account(client: nil)

    read "/lakeraven-ehr/Patient/1"

    assert_no_rpms_connection("ENV pair naming no client")
    assert_no_client_built
    refute held?(service_key)
  end

  # 1d.
  test "a deployment-wide rpms.service_account credentials entry signs no client on" do
    wide = { service_account: { access_code: ACCESS_CODE, verify_code: VERIFY_CODE } }
    configure_credentials_accounts({}, extra: wide)

    [ @token, token_for(client_app_b) ].each do |token|
      read "/lakeraven-ehr/Patient/1", token

      assert_no_rpms_connection("deployment-wide entry")
      refute held?(service_key(token))
    end
    assert_no_client_built
  end

  # 1a. The client's credentials entry alone decides: a partial one is no
  # account, and the ENV pair does not stand in for it.
  test "a partial credentials entry for the client answers 503 though the ENV pair names it" do
    configure_service_account
    configure_credentials_accounts({ @client_app => [ ACCESS_CODE, "" ] })

    read "/lakeraven-ehr/Patient/1"

    assert_no_rpms_connection("partial credentials entry")
    assert_no_client_built
    refute held?(service_key)
  end

  # 2. The back-off is per client: A's refused sign-on does not hold B up.
  test "a refused sign-on backs off its own client only" do
    configure_service_account(access: "WRONG1", verify: "WRONG1!!") # A's codes are wrong
    configure_credentials_accounts({ client_app_b => [ ACCESS_CODE_B, VERIFY_CODE_B ] })
    token_b = token_for(client_app_b)

    read "/lakeraven-ehr/Patient/1"
    assert_no_rpms_connection("client A, refused")
    assert_equal 1, @clients.size

    read "/lakeraven-ehr/Patient/1", token_b # well inside SERVICE_SIGNON_BACKOFF
    assert_read_ok "client B, inside A's back-off"
    assert_equal 2, @clients.size, "B signs on while A is backed off"
    assert_equal SERVICE_DUZ_B.to_s, @clients[1].duz.to_s
    assert_equal [ SERVICE_DUZ_B.to_s ], service_duzes(@clients[1])
    assert_equal [ "#{ACCESS_CODE_B};#{VERIFY_CODE_B}" ], @clients[1].av_codes
    assert held?(service_key(token_b))

    read "/lakeraven-ehr/Patient/1"
    assert_no_rpms_connection("client A, still backed off")
    assert_equal 2, @clients.size, "A's next request inside the back-off opens no connection"
    assert_equal 2, @clients.sum(&:signons), "and sends no sign-on"
    refute held?(service_key)

    read "/lakeraven-ehr/Patient/1", token_b
    assert_read_ok "client B again"
    assert_equal 2, @clients.size
  end

  # 3a. A lease never outlives its token: the time the sign-on took is not
  # added to the lease.
  test "a slow sign-on leases the connection for no longer than the token has left" do
    configure_service_account
    token = token_for(@client_app, expires_in: 300)
    slow_sign_on 100.seconds
    touches = spy_on_pool_touch

    read "/lakeraven-ehr/Patient/1", token

    assert_read_ok "a token with 200 seconds left after the sign-on"
    kept = touches.select { |touch| touch[:key] == service_key(token) }
    assert_predicate kept, :any?, "the lease was touched"
    kept.each do |touch|
      left = token.expires_at - touch[:at]
      assert_operator touch[:idle_for], :<=, left,
                      "the lease is kept #{touch[:idle_for]}s, the token has #{left}s left"
      assert_operator touch[:idle_for], :>, 0
    end
  end

  # 3b.
  test "a token that expires during the sign-on gets no lease" do
    configure_service_account
    token = token_for(@client_app, expires_in: 60)
    slow_sign_on 120.seconds
    touches = spy_on_pool_touch

    read "/lakeraven-ehr/Patient/1", token

    assert_no_rpms_connection("token expired during the sign-on")
    assert_equal 1, @clients.size
    refute held?(service_key(token)), "no lease outlives its token"
    assert @clients[0].disconnected, "the connection that was just signed on is logged off"
    assert_empty @clients[0].rpcs_after_signon, "nothing was read on it"
    assert_empty touches.select { |touch| touch[:key] == service_key(token) }, "and it was never kept"
  end

  # 3c. No clamp up to one second.
  test "a token with less than one whole second left gets no lease" do
    configure_service_account
    token = token_for(@client_app, expires_in: 300)
    touches = spy_on_pool_touch
    travel_to token.expires_at - 0.4.seconds, with_usec: true

    read "/lakeraven-ehr/Patient/1", token

    refute_equal 401, response.status, "the token itself is still good"
    assert_no_rpms_connection("0.4 seconds left")
    refute held?(service_key(token))
    assert_empty @clients.reject(&:disconnected), "no connection is left open"
    assert_empty touches, "nothing was kept"
  end

  # 4. Only a Backend Services token's revocation ends the application's
  # service-account session ("the lease is shared by an application's tokens
  # and released when any of them is revoked" keeps that half). A token of the
  # same application that is not one (a person's, a browser session's) never
  # rode the lease, and revoking it leaves the lease alone.
  NOT_BACKEND_SERVICES = {
    "with a resource owner" => { resource_owner_id: 9001 },
    "with a resource owner and user/ scopes" => { resource_owner_id: 9002, scopes: "user/Patient.rs user/ServiceRequest.rs" },
    "of a browser session" => { browser_session: true }
  }.freeze

  NOT_BACKEND_SERVICES.each do |label, attributes|
    test "revoking a token #{label} does not release its application's service-account lease" do
      configure_service_account
      read "/lakeraven-ehr/Patient/1"
      assert_read_ok
      key = service_key
      assert held?(key)
      used = @clients[0].rpcs.size
      other = Doorkeeper::AccessToken.create!(
        { application: @client_app, scopes: SYSTEM_SCOPES, expires_in: 300 }.merge(attributes)
      )
      assert_equal @token.application_id, other.application_id

      other.revoke

      assert_predicate other.reload, :revoked?
      assert held?(key), "the application's backend tokens keep their service-account session"
      refute @clients[0].disconnected, "RPMS did not log the service account off"
      read "/lakeraven-ehr/Patient/1"
      assert_read_ok "the backend token, after the other token was revoked"
      assert_equal 1, @clients.size, "on the same connection: no second sign-on"
      assert_operator @clients[0].rpcs.size, :>, used
    end
  end
end
