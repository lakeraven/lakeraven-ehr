# frozen_string_literal: true

require "test_helper"
require "securerandom"

# Live (rpms-ux S-REG-20, S-REG-21): the front-desk persona keeps a registered
# patient current on a real RPMS. It WRITES patients, so it runs only against a
# throwaway container and only when asked twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
# Each test registers its own patient through the screen first, edits it through
# the screen, then reads FileMan back (DDR GETS ENTRY DATA), not the app's answer.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9142 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_edit_patient_test.rb
class LiveRegistrationEditPatientTest < ActionDispatch::IntegrationTest
  include RegistrationFormHelper

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  # A patient registered through the screen, with an SSN no one has.
  def registered_patient(ssn: "6660#{format('%05d', rand(100_000))}")
    letters = Array.new(6) { ("A".."Z").to_a.sample }.join
    get "/lakeraven-ehr/registration/patients/new", params: { tribe_search: "A" }
    tribe = css_select("input[name='registration[tribe_ien]']").first["value"]
    get "/lakeraven-ehr/registration/patients/new", params: { community_search: "WAPANUCKA" }
    community = css_select("input[name='registration[community_ien]']").first["value"]
    entry = { name: "LIVEEDIT,#{letters}", sex: "F", dob: Date.new(1950, 1 + rand(12), 1 + rand(28)).iso8601, ssn: ssn,
              tribe_ien: tribe, community_ien: community }
    submit_registration(entry)
    if response.status == 409
      # Someone on the build shares the date of birth: the clerk reviews and says this is a different person.
      token = css_select("#confirm-different-person input[name='review_token']").first["value"]
      post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: token, registration: entry }
    end
    assert_response :redirect
    [ response.location[%r{/registration/patients/(\d+)\z}, 1].to_i, entry ]
  end

  def fileman(file, dfn, fields)
    client = RpmsRpc.client
    reply = client.with_context("CIAV VUECENTRIC") do
      RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{dfn},", fields: fields, flags: "I")
    end
    assert reply && !reply[:error], "DDR GETS ENTRY DATA on ##{file} #{dfn}: #{reply.inspect}"
    reply[:fields].transform_values { |f| f[:internal].to_s }
  end

  def edit_demographics(dfn)
    get "/lakeraven-ehr/registration/patients/#{dfn}/demographics/edit"
    assert_response :ok
    form = css_select("#demographics-form").first
    values = form.css("input[name^='demographics['], select[name^='demographics[']").each_with_object({}) do |input, out|
      key = input["name"][/\[(\w+)\]/, 1]
      next if input["type"] == "radio" && !input["checked"]

      out[key] = input.name == "select" ? input.css("option[selected]").first&.[]("value").to_s : input["value"].to_s
    end
    values
  end

  test "S-REG-20.1 S-REG-20.10 demographics and a name correction are filed to PATIENT and IHS PATIENT" do
    dfn, entry = registered_patient
    form = edit_demographics(dfn)
    corrected = entry[:name].sub("LIVEEDIT", "LIVEEDITT")

    patch "/lakeraven-ehr/registration/patients/#{dfn}/demographics",
          params: { demographics: form.merge("name" => corrected, "dob" => "1951-02-03", "sex" => "M", "marital_status" => "2",
                                             "religion" => "1", "birth_city" => "SPRINGFIELD", "birth_state" => "27",
                                             "employer" => "1", "employment_status" => "FULL-TIME") }

    assert_redirected_to "/lakeraven-ehr/registration/patients/#{dfn}"
    follow_redirect!
    assert_select "#registration-notice", text: /Demographics saved\./
    assert_select "#demographics [data-field='employment_status']", text: "Full-time"
    assert_equal({ ".01" => corrected, ".02" => "M", ".03" => "2510203", ".05" => "2", ".08" => "1", ".092" => "SPRINGFIELD", ".093" => "27" },
                 fileman("2", dfn, ".01;.02;.03;.05;.08;.092;.093"))
    assert_equal({ ".19" => "1", ".21" => "1" }, fileman("9000001", dfn, ".19;.21"))
  end

  test "S-REG-20.7 an SSN already on another patient is refused with RPMS's reason, and nothing is filed" do
    _, other = registered_patient
    dfn, entry = registered_patient
    form = edit_demographics(dfn)

    patch "/lakeraven-ehr/registration/patients/#{dfn}/demographics",
          params: { demographics: form.merge("ssn" => other[:ssn], "marital_status" => "2") }

    assert_response :unprocessable_content
    assert_select "#demographics-alert", text: /SSN already used by another patient\./
    assert_equal({ ".05" => "", ".09" => entry[:ssn] }, fileman("2", dfn, ".05;.09"))
  end

  test "S-REG-21.1 S-REG-21.5 the address, phones and email are filed, and a zip RPMS refuses is not" do
    dfn, = registered_patient
    address = { address_line1: "12 EXAMPLE RD", address_line2: "", address_line3: "", city: "ANYWHERE", state: "27",
                zip: "59001", phone_home: "406-555-0142", phone_work: "406-555-0143", phone_other: "406-555-0144",
                email: "liveedit@example.test" }

    patch "/lakeraven-ehr/registration/patients/#{dfn}/address", params: { address: address.merge(zip: "5900") }
    assert_response :unprocessable_content
    assert_select "#address-alert", text: /Enter 5 or 9 digit zip code\./
    assert_equal "", fileman("2", dfn, ".116")[".116"]

    patch "/lakeraven-ehr/registration/patients/#{dfn}/address", params: { address: address }
    assert_redirected_to "/lakeraven-ehr/registration/patients/#{dfn}"
    assert_equal({ ".111" => "12 EXAMPLE RD", ".114" => "ANYWHERE", ".115" => "27", ".116" => "59001", ".131" => "406-555-0142",
                   ".132" => "406-555-0143" }, fileman("2", dfn, ".111;.114;.115;.116;.131;.132"))
    assert_equal({ "1801" => "406-555-0144", "1802" => "liveedit@example.test" }, fileman("9000001", dfn, "1801;1802"))
  end
end
