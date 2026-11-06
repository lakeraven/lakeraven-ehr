# frozen_string_literal: true

require "test_helper"

# Live (rpms-ux S-REG-07.1): the registration persona records a patient's tribe,
# blood quantum and eligibility on a real RPMS, and FileMan confirms IHS PATIENT
# (#9000001) holds each value. It WRITES, so it runs only against a throwaway
# container and only when asked twice (LIVE_RPMS=1 and LIVE_RPMS_WRITES=1).
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9144 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_eligibility_test.rb
class LiveRegistrationEligibilityTest < ActionDispatch::IntegrationTest
  DFN = 990_053 # CHARLIE,SKYLER on the pinned build

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PREG123", password: "PREG123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  def path = "/lakeraven-ehr/registration/patients/#{DFN}/eligibility"

  def fileman(field)
    got = RpmsRpc.client.with_context("CIAV VUECENTRIC") do
      RpmsRpc::DdrFileman.gets_entry(file: "9000001", iens: "#{DFN},", fields: field, flags: "I")
    end
    flunk "FileMan read #9000001 #{field}: #{got.inspect}" if got.nil? || got[:error]
    got.dig(:fields, field, :internal).to_s
  end

  test "S-REG-07.1 eligibility, classification, tribe, quantums and enrollment number are filed on IHS PATIENT" do
    patch path, params: { tribe_search: "KWETHLUK", eligibility: { eligibility_status: "D" } }
    assert_response :ok
    tribe = css_select("label[data-tribe] input[type='radio']").first["value"]
    get "#{path}/edit"
    classification = css_select("select[name='eligibility[classification_ien]'] option").find { |o| o.text == "INDIAN/ALASKA NATIVE" }["value"]
    number = "ZZ#{rand(10_000..99_999)}"

    patch path, params: { commit: "Save", eligibility: { eligibility_status: "D", classification_ien: classification, tribe_ien: tribe,
                                                         blood_quantum: "1/2", tribe_quantum: "1/4", enrollment_number: number } }
    assert_redirected_to "/lakeraven-ehr/registration/patients/#{DFN}"

    assert_equal({ "1112" => "D", "1111" => classification, "1108" => tribe, "1110" => "1/2", "1109" => "1/4", ".07" => number },
                 %w[1112 1111 1108 1110 1109 .07].to_h { |f| [ f, fileman(f) ] })

    get "#{path}/edit"
    assert_select "input[name='eligibility[enrollment_number]'][value='#{number}']"
  end
end
