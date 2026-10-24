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
    attr_reader :signons, :rpcs

    def initialize(greeting: "MANAGER,SYSTEM signed on.  Good evening", reject: false, denied: [])
      super(host: "127.0.0.1", port: 9100)
      @greeting = greeting
      @reject = reject
      @denied = denied
      @signons = []
      @rpcs = []
      @connected = false
    end

    def connect(*) = (@connected = true)
    def connected? = @connected

    def authenticate(access_code, verify_code, **)
      @signons << [ access_code, verify_code ]
      raise RpmsRpc::Client::AuthenticationError, "CIA sign-on rejected" if @reject

      { success: true, user: "PROVIDER,TEST", duz: 77, greeting: @greeting }
    end

    def call_rpc_raw(name, *)
      @rpcs << name
      raise RpmsRpc::Client::RpcError, "4 Access denied for remote procedure: #{name}" if @denied.include?(name)

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

  def service = Lakeraven::EHR::AuthenticationService.new

  def use(client)
    RpmsRpc.configure { |c| c.client = client }
    client
  end
end
