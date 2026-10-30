# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/cia_client"

# Each signed-in user's requests run on that user's own RPMS connection
# (ADR 0011, #585). The process holds no shared client: sign-in opens a fresh
# connection and the pool holds it under the session's key; every request runs
# inside it; every way the session ends releases it.
#
# The CIA client is stood in for at the gem boundary: it signs on as the user
# its codes name and answers sign-on's reads as CiaClient does. The clinic list
# is stood in for too, and names its clinic after the DUZ of whichever
# connection the request ran on, so the page shows whose connection served it.
class PerUserRpmsConnectionTest < ActionDispatch::IntegrationTest
  USERS = { "PSCH123" => [ 208, "PROFILE,SCHED" ], "PSCH456" => [ 209, "PROFILE,SCHED2" ] }.freeze

  class UserClient < RpmsRpc::CiaClient
    attr_reader :disconnected, :rpcs

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
      { success: true, user: name, duz: @duz, greeting: "#{name} signed on.  Good evening" }
    end

    # ORWU USERINFO (class 3), CIAVCXUS HASKEYS (SDZMENU only), ORWU HAS OPTION
    # ACCESS (CIAV VUECENTRIC), ORWU USERINFO's DTIME, framed as a CIA broker does.
    def call_rpc_raw(name, *params)
      @rpcs << name
      body = case name
      when "ORWU USERINFO" then "#{@duz}^USER^3^1^1^3^0^99999^20^1^1^5^DEMO.IHS.GOV^1^180"
      when "CIAVCXUS HASKEYS" then params.first.to_s.split("^", -1).map { |k| k == "SDZMENU" ? "1" : "0" }.join("^")
      when "ORWU HAS OPTION ACCESS" then params.first == "CIAV VUECENTRIC" ? "1" : "0"
      else ""
      end
      "\x01\x00".b + body.b
    end
  end

  setup do
    @clients = []
    clients = @clients
    RpmsRpc.reset! # no shared client in a pooled process
    Lakeraven::EHR::RpmsSessions.configure!(factory: -> { UserClient.new.tap { |c| clients << c } }, max_sessions: 4, keeper: false)
    sched = RpmsRpc::Scheduling.singleton_class
    sched.alias_method(:__resources, :resources)
    RpmsRpc::Scheduling.define_singleton_method(:resources) do
      [ { id: 1, name: "CLINIC OF DUZ #{RpmsRpc.client.duz}", inactive: false, time_scale: 15, hospital_location_id: 3,
          view: true, overbook: false, modify_schedule: false, modify_appointments: true } ]
    end
  end

  teardown do
    sched = RpmsRpc::Scheduling.singleton_class
    if sched.method_defined?(:__resources) # restore only what setup installed
      sched.alias_method(:resources, :__resources)
      sched.remove_method(:__resources)
    end
    # The pool itself is reset before every test (GlobalStoreIsolation).
  end

  def configure_pool(max_sessions:)
    Lakeraven::EHR::RpmsSessions.reset!
    clients = @clients
    Lakeraven::EHR::RpmsSessions.configure!(factory: -> { UserClient.new.tap { |c| clients << c } },
                                            max_sessions: max_sessions, keeper: false)
  end

  def sign_in(access_code)
    open_session do |s|
      s.post "/lakeraven-ehr/login", params: { username: access_code, password: "VERIFY" }
      s.assert_redirected_to "/lakeraven-ehr/dashboard"
    end
  end

  def clinic_shown(s)
    s.get "/lakeraven-ehr/scheduling"
    s.assert_response :ok
    s.css_select("#resources a").map(&:text).first
  end

  test "two users signed in at once each see their own connection's answers, in any order" do
    first = sign_in("PSCH123")
    second = sign_in("PSCH456") # signs on after the first

    assert_nil RpmsRpc.configuration.client, "the process holds no shared client"
    3.times do
      assert_equal "CLINIC OF DUZ 208", clinic_shown(first)
      assert_equal "CLINIC OF DUZ 209", clinic_shown(second)
    end
    assert_equal 2, @clients.size, "each sign-in opened a connection of its own"
  end

  test "signing out closes the user's connection and leaves the other user's open" do
    first = sign_in("PSCH123")
    second = sign_in("PSCH456")

    first.delete "/lakeraven-ehr/logout"
    assert @clients[0].disconnected, "RPMS logs the signed-out user off"
    refute @clients[1].disconnected
    assert_equal "CLINIC OF DUZ 209", clinic_shown(second)
  end

  test "a request after the user's connection has ended sends them to sign in again" do
    first = sign_in("PSCH123")
    Lakeraven::EHR::RpmsSessions.release(first.session[:rpms_pool_key]) # as the keeper does at the idle limit

    first.get "/lakeraven-ehr/scheduling"
    first.assert_redirected_to "/lakeraven-ehr/login"
    assert_equal "Your RPMS session ended. Sign in again.", first.flash[:alert]
  end

  test "a refused sign-in closes the connection it opened and pools nothing" do
    s = open_session
    s.post "/lakeraven-ehr/login", params: { username: "NOSUCH", password: "VERIFY" }

    assert(@clients.all?(&:disconnected), "a connection that signed no one on is closed")
    assert_nil s.session[:rpms_pool_key]
  end

  test "outside a signed-in user's request, an RPMS call has no connection to run on" do
    sign_in("PSCH123")

    assert_raises(RpmsRpc::NotConfiguredError) { RpmsRpc.client }
  end
# -- from the review of #766 ----------------------------------------------

test "the patient chart runs on the signed-in user's own connection" do
  first = sign_in("PSCH123")
  before = @clients[0].rpcs.size

  first.get "/lakeraven-ehr/patients/1"
  refute_equal 503, first.response.status, "the chart had no RPMS connection of its own"
  assert_operator @clients[0].rpcs.size, :>, before, "the chart read RPMS on the user's connection"
end

test "signing in again elsewhere revokes the earlier session and closes its connection" do
  earlier = sign_in("PSCH123")
  later = sign_in("PSCH123") # the same user, another browser

  assert @clients[0].disconnected, "the earlier browser's connection is closed"
  earlier.get "/lakeraven-ehr/scheduling"
  earlier.assert_redirected_to "/lakeraven-ehr/login"
  assert_equal "CLINIC OF DUZ 208", clinic_shown(later)
end

test "a connection the broker dropped ends the session, whatever the pool holds" do
  first = sign_in("PSCH123")
  @clients[0].disconnect # the broker closed it

  first.get "/lakeraven-ehr/dashboard"
  first.assert_redirected_to "/lakeraven-ehr/login"
  refute Lakeraven::EHR::RpmsSessions.held?(first.session[:rpms_pool_key])
end

test "at capacity a new sign-in is refused and no signed-in user is evicted" do
  configure_pool(max_sessions: 1)
  reading = sign_in("PSCH123")

  late = open_session
  late.post "/lakeraven-ehr/login", params: { username: "PSCH456", password: "VERIFY" }
  assert_equal 503, late.response.status
  assert @clients.last.disconnected, "the refused sign-in's connection is closed"
  assert_nil late.session[:duz], "the refused sign-in holds no session"
  refute @clients[0].disconnected, "the user already signed in keeps their connection"
  assert_equal "CLINIC OF DUZ 208", clinic_shown(reading)
end

end
