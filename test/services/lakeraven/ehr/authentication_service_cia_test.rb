# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/cia_client"

# Sign-on over a CIA broker (#539). CIA refuses every RPC but the CIANB* ones
# until CIANBRPC AUTH has set a DUZ, so the XUS SIGNON SETUP / XUS AV CODE
# sequence the XWB path uses can never sign on there: the client's own
# sign-on is the only way in. The XWB path is covered through the mocked
# broker in sso_session_token_bridge_test.rb.
class AuthenticationServiceCiaTest < ActiveSupport::TestCase
  # A CiaClient with the wire replaced: records what the service asked of it
  # and answers the sign-on the way CiaClient#authenticate does.
  class FakeCiaClient < RpmsRpc::CiaClient
    attr_reader :signons, :rpcs, :callers

    def initialize(greeting: "MANAGER,SYSTEM signed on.  Good evening", reject: false, denied: [])
      super(host: "127.0.0.1", port: 9100)
      @greeting = greeting
      @reject = reject
      @denied = denied
      @signons = []
      @rpcs = []
      @callers = []
      @connected = false
    end

    def connect(*) = (@connected = true)
    def connected? = @connected

    def authenticate(access_code, verify_code, **caller)
      @signons << [ access_code, verify_code ]
      @callers << caller
      raise RpmsRpc::Client::AuthenticationError, "CIA sign-on rejected" if @reject

      @session_uid = "405"

      { success: true, user: "PROVIDER,TEST", duz: 77, greeting: @greeting }
    end

    # ORWU USERINFO for the signed-on DUZ, as a CIA broker frames it (sequence
    # byte, 0x00, body): piece 3 is USRCLS, 3 = provider. Sign-on reads the
    # user class from it and fails closed without one (rpms-rpc #236).
    USERINFO_REPLY = "\x01\x00".b + "77^PROVIDER,TEST^3^1^1^3^0^99999^20^1^1^5^DEMO.IHS.GOV^1^180".b

    def call_rpc_raw(name, *params)
      @rpcs << name
      raise RpmsRpc::Client::RpcError, "4 Access denied for remote procedure: #{name}" if @denied.include?(name)

      return USERINFO_REPLY if name == "ORWU USERINFO"
      # CIAVCXUS HASKEYS: this user holds none of the names asked.
      return "\x01\x00".b + params.first.to_s.split("^", -1).map { "0" }.join("^").b if name == "CIAVCXUS HASKEYS"
      # ORWU HAS OPTION ACCESS: a CIA sign-on binds to CIAV VUECENTRIC, so it holds that.
      return "\x01\x00".b + (params.first == "CIAV VUECENTRIC" ? "1" : "0").b if name == "ORWU HAS OPTION ACCESS"

      ""
    end
  end

  setup do
    @previous_client = RpmsRpc.configuration.client
  end

  teardown do
    RpmsRpc.configure { |c| c.client = @previous_client }
  end

  test "signs on through the CIA client and never sends XUS AV CODE" do
    client = use(FakeCiaClient.new)

    result = service.authenticate(access_code: "PROV123", verify_code: "VERIFY")

    assert result.success?
    assert_equal "77", result.value[:duz]
    assert_equal "PROVIDER,TEST", result.value[:name]
    assert_equal "provider", result.value[:user_type], "the class is ORWU USERINFO USRCLS 3"
    assert_equal [ [ "PROV123", "VERIFY" ] ], client.signons
    refute_includes client.rpcs, "XUS AV CODE"
    refute_includes client.rpcs, "XUS SIGNON SETUP"
  end

  test "opens the connection before signing on" do
    client = use(FakeCiaClient.new)

    service.authenticate(access_code: "PROV123", verify_code: "VERIFY")

    assert client.connected?
  end

  test "a CIA refusal is a failed sign-on, not an exception" do
    use(FakeCiaClient.new(reject: true))

    result = service.authenticate(access_code: "PROV123", verify_code: "WRONG")

    refute result.success?
    assert_equal "Invalid access/verify code", result.error
  end

  # A least-privilege clinician signs on under CIAV VUECENTRIC, whose RPC
  # multiple lacks XUS GET USER INFO. The DUZ is already verified by then;
  # a denied display-name read must not turn the sign-on into a 500.
  test "a denied user-info read keeps the sign-on and the name the client resolved" do
    use(FakeCiaClient.new(denied: [ "XUS GET USER INFO" ]))

    result = service.authenticate(access_code: "PROV123", verify_code: "VERIFY")

    assert result.success?
    assert_equal "77", result.value[:duz]
    assert_equal "PROVIDER,TEST", result.value[:name]
  end

  test "a greeting that demands a verify-code change is reported to the caller" do
    use(FakeCiaClient.new(greeting: "2 1^VERIFY CODE must be changed before continued use. Good evening"))

    result = service.authenticate(access_code: "SYS123", verify_code: "VERIFY")

    assert result.success?
    assert result.value[:verify_needs_change]
  end

  test "an ordinary greeting does not demand a change" do
    use(FakeCiaClient.new)

    result = service.authenticate(access_code: "PROV123", verify_code: "VERIFY")

    refute result.value[:verify_needs_change]
  end

  private

# docs/identity-passthrough.md: RPMS records the workstation and the
# browser's address against the sign-on, and the CIA session it opened is
# kept so audit rows can lead to it.
test "tells RPMS the workstation and the browser's address, and keeps the CIA session" do
  client = use(FakeCiaClient.new)

  result = service.authenticate(access_code: "PROV123", verify_code: "VERIFY", client_ip: "203.0.113.9")

  assert_equal [ { workstation: Lakeraven::EHR::AuthenticationService.workstation, workstation_ip: "203.0.113.9" } ], client.callers
  assert_match(/\Alakeraven-ehr /, Lakeraven::EHR::AuthenticationService.workstation)
  assert_equal "405", result.value[:rpms_session_id]
end

test "without a browser address, none is sent" do
  client = use(FakeCiaClient.new)

  service.authenticate(access_code: "PROV123", verify_code: "VERIFY")

  assert_nil client.callers.first[:workstation_ip]
end

  def service = Lakeraven::EHR::AuthenticationService.new

  def use(client)
    RpmsRpc.configure { |c| c.client = client }
    client
  end
end
