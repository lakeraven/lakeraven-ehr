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

  test "when RPMS names no limit, the app's own applies" do
    with_timed_read(nil) do
      sign_in
      assert_nil session[:rpms_idle_seconds]

      travel 20.minutes do
        get "/lakeraven-ehr/dashboard"
        assert_response :ok
      end
    end
  end
end
