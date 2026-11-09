# frozen_string_literal: true

require "test_helper"

# The public demo's sign-in gate (#952), at the HTTP level the browser test
# cannot reach: a sign-in posted straight past the terms page is not attempted,
# and with demo mode off the accept route is not there.
class DemoModeSignInGateTest < ActionDispatch::IntegrationTest
  setup do
    Lakeraven::EHR::LoginThrottle.reset!
    @demo_mode_was = Lakeraven::EHR.configuration.demo_mode
  end

  teardown do
    Lakeraven::EHR.configuration.demo_mode = @demo_mode_was
  end

  test "with demo mode on, a sign-in posted before the terms are accepted signs nobody in" do
    Lakeraven::EHR.configuration.demo_mode = true

    post "/lakeraven-ehr/login", params: { username: "testprovider", password: "test123" }
    assert_redirected_to "/lakeraven-ehr/login"
    assert_nil session[:duz]

    follow_redirect!
    assert_select "h1", text: "Before you sign in"
  end

  test "with demo mode on, the same sign-in works once the terms are accepted" do
    Lakeraven::EHR.configuration.demo_mode = true

    post "/lakeraven-ehr/login/demo_terms"
    assert_redirected_to "/lakeraven-ehr/login"

    post "/lakeraven-ehr/login", params: { username: "testprovider", password: "test123" }
    assert_redirected_to "/lakeraven-ehr/dashboard"
    assert_equal 301, session[:duz].to_i
  end

  test "with demo mode off, accepting the terms is not a route" do
    Lakeraven::EHR.configuration.demo_mode = false

    post "/lakeraven-ehr/login/demo_terms"
    assert_response :not_found
  end

  test "demo mode is off unless DEMO_MODE is exactly 1" do
    { nil => false, "" => false, "0" => false, "true" => false, "1" => true }.each do |value, expected|
      with_env("DEMO_MODE", value) do
        assert_equal expected, Lakeraven::EHR::Configuration.new.demo_mode, "DEMO_MODE=#{value.inspect}"
      end
    end
  end

  private

  def with_env(name, value)
    was = ENV[name]
    value.nil? ? ENV.delete(name) : ENV[name] = value
    yield
  ensure
    was.nil? ? ENV.delete(name) : ENV[name] = was
  end
end
