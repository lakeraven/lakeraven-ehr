# frozen_string_literal: true

require "test_helper"

# A browser session lasts as long as RPMS lets the user sit idle: their DTIME
# (Authentication.timed_read), read at sign-on, not a limit of the app's own.
class RpmsIdleLimitTest < ActionDispatch::IntegrationTest
  def with_timed_read(seconds)
    auth = RpmsRpc::Authentication.singleton_class
    auth.alias_method(:__timed_read, :timed_read)
    RpmsRpc::Authentication.define_singleton_method(:timed_read) { |_duz| seconds }
    yield
  ensure
    auth.alias_method(:timed_read, :__timed_read)
    auth.remove_method(:__timed_read)
  end

  def sign_in
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "testprovider", password: "test123" }
    assert_redirected_to "/lakeraven-ehr/dashboard"
  end

  test "the session ends when the user's RPMS idle limit passes, not the app's" do
    with_timed_read(600) do
      sign_in
      assert_equal 600, session[:rpms_idle_seconds]

      travel 599.seconds do
        get "/lakeraven-ehr/dashboard"
        assert_response :ok
      end
      travel 1200.seconds do
        get "/lakeraven-ehr/dashboard"
        assert_redirected_to "/lakeraven-ehr/login"
      end
    end
  end

  test "when RPMS names no limit, the site's applies" do
    with_timed_read(nil) do
      sign_in
      assert_nil session[:rpms_idle_seconds]

      travel 29.minutes do
        get "/lakeraven-ehr/dashboard"
        assert_response :ok
      end
      travel (29 + 31).minutes do
        get "/lakeraven-ehr/dashboard"
        assert_redirected_to "/lakeraven-ehr/login", "31 minutes after the last request"
      end
    end
  end

  # PROFILE,MD's DTIME is 9999 s on the demo build. RPMS may make the limit
  # stricter, never looser than the site's (NIST SP 800-63B-3 AAL2: 30 minutes).
  test "an RPMS limit longer than the site's is held to the site's" do
    with_timed_read(9999) do
      sign_in

      travel 31.minutes do
        get "/lakeraven-ehr/dashboard"
        assert_redirected_to "/lakeraven-ehr/login"
      end
    end
  end

  test "a site can set a shorter limit" do
    Lakeraven::EHR.configuration.session_idle_limit = 15.minutes
    with_timed_read(600) do
      sign_in

      travel 9.minutes do
        get "/lakeraven-ehr/dashboard"
        assert_response :ok
      end
    end
    with_timed_read(9999) do
      sign_in

      travel 16.minutes do
        get "/lakeraven-ehr/dashboard"
        assert_redirected_to "/lakeraven-ehr/login"
      end
    end
  ensure
    Lakeraven::EHR.reset_configuration!
  end

  # NIST SP 800-63B-3 AAL2: re-authenticate at least every 12 hours, however
  # active the user is.
  test "an active session ends 12 hours after sign-on" do
    with_timed_read(nil) do
      sign_in
      signed_in = Time.current

      # A request every 25 minutes, inside the 30-minute idle limit, to 11 h 40.
      (1..28).each do |step|
        travel_to(signed_in + (step * 25).minutes) { get "/lakeraven-ehr/dashboard" }
        assert_response :ok, "active at #{step * 25} minutes"
      end
      travel_to(signed_in + 12.hours + 1.minute) do
        get "/lakeraven-ehr/dashboard"
        assert_redirected_to "/lakeraven-ehr/login"
      end
    end
  end
end
