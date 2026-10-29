# frozen_string_literal: true

require "test_helper"

# #724: when RPMS does not answer, registration and scheduling say so instead of
# failing with a 500. The broker itself fails here, so the real gem modules run
# and raise their own errors on the way up.
class RpmsUnavailablePagesTest < ActionDispatch::IntegrationTest
  include RegistrationFormHelper

  NOT_ANSWERED = "RPMS did not answer"

  def sign_in(keys, duz:, name:)
    post "/lakeraven-ehr/test_session", params: { duz: duz, user_type: "user", user_name: name, security_keys: keys }
  end

  # Every call on the broker raises error; yields a count of the calls made, so a
  # test can tell the page really asked RPMS.
  def with_broker_raising(error)
    client = RpmsRpc.client
    calls = []
    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |name|
      client.singleton_class.alias_method(:"__#{name}", name)
      client.define_singleton_method(name) do |rpc, *|
        calls << rpc
        raise error
      end
    end
    yield calls
  ensure
    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |name|
      client.singleton_class.alias_method(name, :"__#{name}")
      client.singleton_class.remove_method(:"__#{name}")
    end
  end

  def assert_not_answered(calls)
    assert_response :service_unavailable
    assert_select "[role=alert]", text: /#{NOT_ANSWERED}/
    assert calls.any?, "the page asked RPMS"
  end

  test "a registration whose header RPMS does not return says RPMS did not answer" do
    sign_in("registration_menu", duz: "207", name: "PROFILE,REG")
    with_broker_raising(RpmsRpc::Client::ConnectionError.new("connection reset")) do |calls|
      get "/lakeraven-ehr/registration/patients/3"
      assert_not_answered(calls)
    end
  end

  test "the new-patient form says RPMS did not answer when a tribe search cannot be read" do
    sign_in("registration_menu", duz: "207", name: "PROFILE,REG")
    with_broker_raising(RpmsRpc::Client::ConnectionError.new("connection reset")) do |calls|
      get "/lakeraven-ehr/registration/patients/new", params: { tribe_search: "YAK" }
      assert_not_answered(calls)
    end
  end

  test "a registration cut off by a frame error is reported as not confirmed, not as an error" do
    sign_in("registration_menu", duz: "207", name: "PROFILE,REG")
    with_broker_raising(RpmsRpc::Client::FrameTooLongError.new("request too long for the frame")) do |calls|
      submit_registration({ name: "PROBE,ALPHA", sex: "F", dob: "1990-05-01", ssn: "", tribe_ien: "611", community_ien: "16379" })
      assert_response :service_unavailable
      assert_select "#outcome-unknown"
      assert calls.any?, "the page asked RPMS"
    end
  end

  test "scheduling says RPMS did not answer when the clinics cannot be read" do
    sign_in("scheduling_user", duz: "208", name: "PROFILE,SCHED")
    with_broker_raising(RpmsRpc::Client::RpcError.new("no response")) do |calls|
      get "/lakeraven-ehr/scheduling"
      assert_not_answered(calls)
    end
  end

  test "a refusal from RPMS is shown as a refusal, with RPMS's reason" do
    sign_in("scheduling_user", duz: "208", name: "PROFILE,SCHED")
    with_broker_raising(RpmsRpc::Client::RpcRefusedError.new("Access denied for remote procedure: BSDX RESOURCES")) do |calls|
      get "/lakeraven-ehr/scheduling"
      assert_response :forbidden
      assert_select "[role=alert]", text: /RPMS refused.*Access denied for remote procedure: BSDX RESOURCES/m
      assert calls.any?, "the page asked RPMS"
    end
  end
end
