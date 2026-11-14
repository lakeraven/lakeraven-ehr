# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/authentication"

# A SMART Backend Services (system/) token reads RPMS through a broker session
# signed on as the deployment's service account (ADR 0011 section 6, #996),
# keyed to the client application and never to a person. With no service
# account configured the read answers 503 as before; a user/ or patient/ token
# never rides the service account.
#
# The process is set up as a server is: no shared client, and a pool whose
# factory builds a fresh mock broker per sign-on. Each mock carries the suite's
# baseline seeds and one synthetic service-account user (DUZ 4242), and records
# for every RPC the DUZ it held at the moment of the call.
class BackendServiceAccountRpmsTest < ActionDispatch::IntegrationTest
  SERVICE_DUZ = 4242
  ACCESS_CODE = "SVCACCT1"
  VERIFY_CODE = "SVCACCT1!!"
  ENV_KEYS = %w[RPMS_SERVICE_ACCESS_CODE RPMS_SERVICE_VERIFY_CODE].freeze
  # Sent before anyone is signed on, so they carry no DUZ by construction.
  SIGNON_RPCS = [ "XUS SIGNON SETUP", "XUS AV CODE" ].freeze
  NO_CONNECTION = "This request has no RPMS connection of its own."
  SYSTEM_SCOPES = "system/Patient.rs system/ServiceRequest.rs"
  READS = [
    [ "Patient", "/lakeraven-ehr/Patient/1" ],
    [ "ServiceRequest", "/lakeraven-ehr/ServiceRequest?patient=1" ]
  ].freeze

  # The mock broker, as one connection of the pool: connectable, and recording
  # each RPC with the DUZ it ran under.
  class RecordingClient < RpmsRpc::MockClient
    attr_reader :rpcs, :disconnected

    def initialize
      super
      @rpcs = []
      @connected = false
      @disconnected = false
    end

    def connect(*) = (@connected = true)
    def connected? = @connected && !@disconnected
    def disconnect = (@disconnected = true)

    # Client#authenticate's shape, for a sign-on made on the client itself.
    def authenticate(access_code = nil, verify_code = nil, **)
      result = RpmsRpc.with_client(self) do
        RpmsRpc::Authentication.authenticate(access_code: access_code, verify_code: verify_code)
      end
      raise RpmsRpc::Client::AuthenticationError, "Authentication failed" unless result[:success]

      { success: true, duz: result[:duz], user: result[:name] }
    end

    def call_rpc(rpc_name, *params)
      record(rpc_name)
      super
    end

    def call_rpc_lines(rpc_name, *params)
      record(rpc_name)
      super
    end

    def call_rpc_global_array(rpc_name, *params)
      record(rpc_name)
      super
    end

    # The RPCs made once the sign-on exchange itself was over.
    def rpcs_after_signon = rpcs.reject { |rpc| SIGNON_RPCS.include?(rpc[:rpc]) }

    private

    def record(rpc_name)
      @rpcs << { rpc: rpc_name, duz: duz&.to_s }
    end
  end

  setup do
    skip "needs the mock broker" if LIVE_RPMS

    @saved_env = ENV_KEYS.to_h { |key| [ key, ENV.key?(key) ? ENV[key] : :missing ] }
    ENV_KEYS.each { |key| ENV.delete(key) }

    @clients = []
    clients = @clients
    RpmsRpc.reset! # no shared client in a pooled process
    Lakeraven::EHR::RpmsSessions.configure!(
      factory: lambda {
        RecordingClient.new.tap do |client|
          BASELINE_MOCK_SEEDS.call(client)
          client.seed_user(SERVICE_DUZ, credentials: "#{ACCESS_CODE};#{VERIFY_CODE}", name: "SERVICE,ACCOUNT", role: "user")
          clients << client
        end
      },
      max_sessions: 4, keeper: false
    )
    @token = backend_token("backend-client-a", "synthetic-org-a")
  end

  teardown do
    (@saved_env || {}).each { |key, value| value == :missing ? ENV.delete(key) : ENV[key] = value }
    # Later tests get the suite's shared mock back, whatever they include.
    Lakeraven::EHR::RpmsSessions.reset!
    RpmsRpc.mock!(&BASELINE_MOCK_SEEDS) unless LIVE_RPMS
  end

  def configure_service_account(access: ACCESS_CODE, verify: VERIFY_CODE)
    ENV["RPMS_SERVICE_ACCESS_CODE"] = access if access
    ENV["RPMS_SERVICE_VERIFY_CODE"] = verify if verify
  end

  def backend_token(name, organization_id)
    app = Doorkeeper::Application.create!(
      name: name, redirect_uri: "https://example.test/callback",
      scopes: SYSTEM_SCOPES, confidential: true, organization_id: organization_id
    )
    Doorkeeper::AccessToken.create!(application: app, scopes: SYSTEM_SCOPES, expires_in: 300)
  end

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
  test "the lease is reused across requests and released when the token is revoked" do
    configure_service_account

    2.times do
      read "/lakeraven-ehr/Patient/1"
      assert_equal 200, response.status, response.body[0, 300]
    end
    assert_equal 1, @clients.size, "one sign-on serves both reads"
    key = service_key
    assert Lakeraven::EHR::RpmsSessions.held?(key)

    @token.revoke

    refute Lakeraven::EHR::RpmsSessions.held?(key), "revocation releases the service-account lease"
    assert @clients[0].disconnected, "RPMS logs the service account's session off"
    read "/lakeraven-ehr/Patient/1"
    assert_equal 401, response.status
    assert_equal 1, @clients.size, "a revoked token opens no connection"
  end

  # G.
  test "a refused service-account sign-on fails closed" do
    configure_service_account(access: "WRONG1", verify: "WRONG1!!")

    read "/lakeraven-ehr/Patient/1"

    assert_no_rpms_connection("refused sign-on")
    assert_equal 1, @clients.size, "one sign-on was attempted"
    assert @clients.all?(&:disconnected), "a connection that signed no one on is closed"
    refute Lakeraven::EHR::RpmsSessions.held?(service_key), "nothing is held for the token"
  end

  # H.
  test "the lease is keyed to the client application, never to a person" do
    configure_service_account
    other = backend_token("backend-client-b", "synthetic-org-b")

    key = service_key
    refute_equal Lakeraven::EHR::RpmsSessions.key_for(@token), key
    assert_equal "system-app-#{@token.application_id}-token-#{@token.id}", key
    assert_includes key, @token.application_id.to_s
    refute_equal key, service_key(other)

    read "/lakeraven-ehr/Patient/1"
    assert_equal 200, response.status, response.body[0, 300]
    read "/lakeraven-ehr/Patient/1", other
    assert_equal 200, response.status, response.body[0, 300]

    assert_equal 2, @clients.size, "each application's token signs on for itself"
    assert_equal [ SERVICE_DUZ.to_s, SERVICE_DUZ.to_s ], @clients.map { |client| client.duz.to_s }
    assert Lakeraven::EHR::RpmsSessions.held?(key)
    assert Lakeraven::EHR::RpmsSessions.held?(service_key(other))
  end

  # I.
  test "an expired token answers 401 and opens no new connection" do
    configure_service_account
    read "/lakeraven-ehr/Patient/1"
    assert_equal 200, response.status, response.body[0, 300]
    assert_equal 1, @clients.size

    travel 301.seconds

    read "/lakeraven-ehr/Patient/1"
    assert_equal 401, response.status
    assert_equal 1, @clients.size, "an expired token signs nobody on"
  end
end
