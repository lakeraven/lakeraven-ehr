# frozen_string_literal: true

require "test_helper"

# Live (#585, ADR 0011): two demo personas signed in at once, each on their own
# RPMS connection, through the real sign-in and the real pool. Every read in a
# user's scope answers as that user, whichever signed in last; signing one out
# ends their connection and leaves the other's open; and a real page loads on
# its user's connection. Reads only; signing on writes RPMS's sign-on log.
#
#   LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9130 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_per_user_rpms_connection_test.rb
class LivePerUserRpmsConnectionTest < ActionDispatch::IntegrationTest
  setup do
    skip "live: set LIVE_RPMS=1 against a local container" unless defined?(LIVE_RPMS) && LIVE_RPMS
    @shared = RpmsRpc.configuration.client
    RpmsRpc.reset! # a pooled process holds no shared client
    settings = Lakeraven::EHR::Engine.rpms_settings
    Lakeraven::EHR::RpmsSessions.configure!(
      factory: -> { RpmsRpc.client_for(settings[:broker], host: settings[:host], port: settings[:port]) },
      max_sessions: 4, keeper: false
    )
    Lakeraven::EHR::LoginThrottle.reset!
  end

  teardown do
    next unless defined?(LIVE_RPMS) && LIVE_RPMS

    Lakeraven::EHR::RpmsSessions.reset!
    RpmsRpc.configure { |c| c.client = @shared }
  end

  def sign_in(access_code, verify_code)
    open_session do |s|
      s.post "/lakeraven-ehr/login", params: { username: access_code, password: verify_code }
      s.assert_redirected_to "/lakeraven-ehr/"
    end
  end

  # The DUZ RPMS runs this session's RPCs as: CIAVCXUS VIMINFO answers for the
  # connection's own signed-on user.
  def rpms_user_of(s)
    Lakeraven::EHR::RpmsSessions.with_user(s.session[:rpms_pool_key]) do
      Array(RpmsRpc.client.call_rpc("CIAVCXUS VIMINFO")).first.to_s.split("^").first
    end
  end

  test "two signed-in users each run as themselves on their own connection, and signing one out leaves the other" do
    scheduler = sign_in("PSCH123", "PSCH123!!")
    clerk = sign_in("PREG123", "PREG123!!") # signs in after the scheduler

    assert_nil RpmsRpc.configuration.client
    3.times do
      assert_equal scheduler.session[:duz], rpms_user_of(scheduler)
      assert_equal clerk.session[:duz], rpms_user_of(clerk)
    end

    scheduler.get "/lakeraven-ehr/scheduling"
    scheduler.assert_response :ok
    refute_empty scheduler.css_select("#resources a"), "the scheduler's own connection listed their clinics"

    scheduler.delete "/lakeraven-ehr/logout"
    refute Lakeraven::EHR::RpmsSessions.held?(scheduler.session[:rpms_pool_key])
    assert_equal clerk.session[:duz], rpms_user_of(clerk), "the clerk's connection is untouched"
  end
end
