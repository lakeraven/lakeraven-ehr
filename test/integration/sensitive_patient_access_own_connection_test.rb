# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/cia_client"
require_relative "../support/sensitive_patient_access_seeds"

# The sensitive-record check on opening a record (#613) runs on the signed-in
# user's own RPMS connection (ADR 0011, #585): PTSEC^DGSEC4 decides for, and
# writes the DG SECURITY LOG entry under, the user that connection signed on.
#
# The process holds no shared client here, as in PerUserRpmsConnectionTest:
# each sign-in opens a CIA client stood in for at the gem boundary, which
# records the RPCs it was sent and answers the check as a CIA broker frames it.
class SensitivePatientAccessOwnConnectionTest < ActionDispatch::IntegrationTest
  ACCESS_RPC = SensitivePatientAccessSeeds::ACCESS_RPC
  BULLETIN_RPC = SensitivePatientAccessSeeds::BULLETIN_RPC
  USERS = { "PSCH123" => [ 208, "PROFILE,SCHED" ], "PSCH456" => [ 209, "PROFILE,SCHED2" ] }.freeze
  DFN = "1"

  class UserClient < RpmsRpc::CiaClient
    attr_reader :rpcs

    def initialize
      super(host: "127.0.0.1", port: 9100)
      @connected = false
      @disconnected = false
      @rpcs = []
    end

    def connect(*) = (@connected = true)
    def connected? = @connected && !@disconnected
    def disconnect = (@disconnected = true)

    def authenticate(access_code, _verify_code, **)
      raise RpmsRpc::Client::AuthenticationError, "CIA sign-on rejected" unless USERS.key?(access_code)

      @duz, name = USERS.fetch(access_code)
      @session_uid = "4#{@duz}"
      set_authenticated(@duz)
      { success: true, user: name, duz: @duz, greeting: "#{name} signed on.  Good evening" }
    end

    # Sign-on's reads as PerUserRpmsConnectionTest answers them, and the
    # sensitive-record check: "0", not sensitive, for any patient.
    def call_rpc_raw(name, *params)
      @rpcs << { rpc: name, params: params }
      body = case name
      when "ORWU USERINFO" then "#{@duz}^USER^3^1^1^3^0^99999^20^1^1^5^DEMO.IHS.GOV^1^180"
      when "ORWU NPHASKEY" then "0"
      when "ORWU HAS OPTION ACCESS" then params.first == "CIAV VUECENTRIC" ? "1" : "0"
      when ACCESS_RPC then "0\r"
      else ""
      end
      "\x01\x00".b + body.b
    end

    def sent(rpc) = @rpcs.select { |call| call[:rpc] == rpc }
  end

  setup do
    # A session credential writes only where CSRF protection is enforced (#486).
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @clients = []
    clients = @clients
    RpmsRpc.reset! # no shared client in a pooled process
    Lakeraven::EHR::RpmsSessions.configure!(factory: -> { UserClient.new.tap { |c| clients << c } },
                                            max_sessions: 4, keeper: false)
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
    Lakeraven::EHR::AuditEvent.delete_all
  end

  def sign_in(access_code)
    open_session do |s|
      s.post "/lakeraven-ehr/login", params: { username: access_code, password: "VERIFY" }.merge(csrf(s))
      s.assert_redirected_to "/lakeraven-ehr/dashboard"
    end
  end

  # The session-wide authenticity token, from the login page's meta tag.
  def csrf(s)
    s.get "/lakeraven-ehr/login"
    { authenticity_token: s.css_select("meta[name=csrf-token]").first&.[]("content") }
  end

  test "the check is sent on the connection of the user opening the record, and on no other" do
    first = sign_in("PSCH123")
    second = sign_in("PSCH456")
    assert_nil RpmsRpc.configuration.client, "the process holds no shared client"

    second.post "/lakeraven-ehr/patients/#{DFN}/context", params: csrf(second)

    second.assert_redirected_to "/lakeraven-ehr/patients/#{DFN}"
    assert_equal DFN, second.session[Lakeraven::EHR::ClinicianPatientContext::SESSION_KEY]
    assert_empty @clients[0].sent(ACCESS_RPC), "the other user's connection is not asked"
    assert_equal [ DFN ], @clients[1].sent(ACCESS_RPC).map { |call| call[:params].first.to_s },
                 "DG SENSITIVE RECORD ACCESS is sent as the user opening the record"
    assert_empty @clients.flat_map { |c| c.sent(BULLETIN_RPC) }
    assert_nil first.session[Lakeraven::EHR::ClinicianPatientContext::SESSION_KEY]
  end
end
