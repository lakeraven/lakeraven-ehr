# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/cia_client"

# A browser sign-in tells RPMS where it came from, and every audit row of the
# signed-in user names the RPMS session it ran under, so lakeraven-ehr's audit
# trail and RPMS's lead to each other (docs/identity-passthrough.md, ADR 0012
# rule 12). The CIA client is stood in for at the gem boundary: it answers
# sign-on as CiaClient#authenticate does and opens CIA session 405.
class RpmsSessionAuditLinkTest < ActionDispatch::IntegrationTest
  class SignOnClient < RpmsRpc::CiaClient
    attr_reader :callers

    def initialize
      super(host: "127.0.0.1", port: 9100)
      @callers = []
      @connected = false
    end

    def connect(*) = (@connected = true)
    def connected? = @connected

    def authenticate(_access_code, _verify_code, **caller)
      @callers << caller
      @session_uid = "405"
      { success: true, user: "PROVIDER,TEST", duz: 77, greeting: "PROVIDER,TEST signed on.  Good evening" }
    end

    # ORWU USERINFO (class 3, provider), CIAVCXUS HASKEYS (no keys), ORWU HAS
    # OPTION ACCESS (CIAV VUECENTRIC only), framed as a CIA broker frames them.
    def call_rpc_raw(name, *params)
      body = case name
      when "ORWU USERINFO" then "77^PROVIDER,TEST^3^1^1^3^0^99999^20^1^1^5^DEMO.IHS.GOV^1^180"
      when "CIAVCXUS HASKEYS" then params.first.to_s.split("^", -1).map { "0" }.join("^")
      when "ORWU HAS OPTION ACCESS" then params.first == "CIAV VUECENTRIC" ? "1" : "0"
      else ""
      end
      "\x01\x00".b + body.b
    end
  end

  setup do
    @previous_client = RpmsRpc.configuration.client
    @client = SignOnClient.new
    RpmsRpc.configure { |c| c.client = @client }
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::AuditEvent.delete_all
  end

  teardown { RpmsRpc.configure { |c| c.client = @previous_client } }

  test "sign-in sends the browser's address to RPMS, and the user's audit rows name the RPMS session" do
    post "/lakeraven-ehr/login", params: { username: "PROV123", password: "VERIFY" },
                                 headers: { "REMOTE_ADDR" => "203.0.113.9" }
    assert_redirected_to "/lakeraven-ehr/"
    assert_equal "203.0.113.9", @client.callers.last[:workstation_ip]
    assert_equal "405", session[:rpms_session_id]

    get "/lakeraven-ehr/dashboard"
    assert_response :ok

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal "77", event.agent_who_identifier
    assert_equal "405", event.rpms_session_id
  end

  test "a row for a request no RPMS session served names none" do
    get "/lakeraven-ehr/dashboard"

    assert_nil Lakeraven::EHR::AuditEvent.order(:id).last.rpms_session_id
  end
end
