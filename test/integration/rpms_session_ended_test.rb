# frozen_string_literal: true

require "test_helper"

# When the broker has closed the RPMS connection (RPMS ends an idle session on
# its own clock), the browser session ends with it: the user is sent to sign in
# again, which opens a new connection, rather than shown pages that cannot reach
# RPMS or told to "try again" when a retry can never work.
class RpmsSessionEndedTest < ActionDispatch::IntegrationTest
  ENDED = /RPMS session ended/

  def sign_in(keys = "scheduling_user")
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  def with_connection_closed(raise_on_call: false)
    client = RpmsRpc.client
    client.define_singleton_method(:connected?) { false }
    if raise_on_call
      %i[call_rpc call_rpc_lines call_rpc_global_array].each do |name|
        client.singleton_class.alias_method(:"__#{name}", name)
        client.define_singleton_method(name) { |*| raise RpmsRpc::Client::ConnectionError, "Not connected" }
      end
    end
    yield
  ensure
    client.singleton_class.remove_method(:connected?)
    if raise_on_call
      %i[call_rpc call_rpc_lines call_rpc_global_array].each do |name|
        client.singleton_class.alias_method(name, :"__#{name}")
        client.singleton_class.remove_method(:"__#{name}")
      end
    end
  end

  def assert_sent_to_sign_in
    assert_redirected_to "/lakeraven-ehr/login"
    assert_match ENDED, flash[:alert]
    assert_nil session[:duz], "the browser session ended"
  end

  test "a page that does not call RPMS no longer loads once the RPMS connection is closed" do
    sign_in
    with_connection_closed do
      get "/lakeraven-ehr/dashboard"
      assert_sent_to_sign_in
    end
  end

  test "a scheduling page that finds the connection closed sends the user to sign in, not to try again" do
    sign_in
    with_connection_closed(raise_on_call: true) do
      get "/lakeraven-ehr/scheduling"
      assert_sent_to_sign_in
    end
  end

  test "a registration search that finds the connection closed sends the user to sign in" do
    sign_in("registration_menu")
    with_connection_closed(raise_on_call: true) do
      post "/lakeraven-ehr/registration/patients/search", params: { q: "DEMO" }
      assert_sent_to_sign_in
    end
  end
end
