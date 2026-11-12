# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration_parameters"

# Live (lakeraven-ehr#980): the registration forms require the fields the
# signed-on division has set as mandatory in RPMS, REGISTRATION PARAMETERS
# (#9009061) field 1101, on a real RPMS. The site setting is filed first
# through DDR FILER, as a site manager's edit would leave it, and removed after.
# It WRITES, so it runs only against a throwaway container and only when asked
# twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=19180 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_site_required_fields_test.rb
class LiveRegistrationSiteRequiredFieldsTest < ActionDispatch::IntegrationTest
  DFN = 990_009 # INDIA,QUINN, a synthetic seed patient
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze
  SPANISH = 531
  HOME_PHONE = "PHONE NUMBER [RESIDENCE]"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    sign_in
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  def sign_in
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  def facility = RpmsRpc.client.division[:ien]

  def ddr(&block) = RpmsRpc.client.with_context(RpmsRpc::RegistrationParameters::CONTEXT, &block)

  # Adds HOME_PHONE to the division's mandatory fields for PATIENT (#2),
  # required or not, for the block, and removes it after.
  def with_home_phone_mandatory(required)
    LiveRpmsSession.sign_on!
    page = ddr { RpmsRpc::DdrFileman.lister(file: RpmsRpc::RegistrationParameters::MANDATORY_FILE, iens: ",#{facility},", fields: "@;.01I", flags: "IP") }
    file_entry = page[:entries].find { |e| e[:pieces].first == "2" }&.dig(:ien)
    assert file_entry, "the division lists PATIENT (#2) among its mandatory-field files"
    sub = RpmsRpc::RegistrationParameters::MANDATORY_FIELD_FILE
    filed = ddr do
      RpmsRpc::DdrFileman.filer(mode: "ADD", rows: [
        { file: sub, field: ".01", iens: "+1,#{file_entry},#{facility},", value: HOME_PHONE },
        { file: sub, field: ".02", iens: "+1,#{file_entry},#{facility},", value: required ? "1" : "0" }
      ])
    end
    assert filed && filed[:success], "DDR FILER added #{HOME_PHONE}: #{filed.inspect}"
    added = filed[:iens][1]
    sign_in
    yield
  ensure
    if added
      LiveRpmsSession.sign_on!
      ddr { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: sub, field: ".01", iens: "#{added},#{file_entry},#{facility},", value: "@" } ]) }
    end
  end

  def address_form
    get "#{BASE}/address/edit"
    assert_response :ok
    css_select("#address-form input[name^='address['], #address-form select[name^='address[']").each_with_object({}) do |input, out|
      key = input["name"][/\[(\w+)\]/, 1]
      out[key] = input.name == "select" ? input.css("option[selected]").first&.[]("value").to_s : input["value"].to_s
    end
  end

  test "a home phone the site requires is marked, and a save without it is refused by name" do
    with_home_phone_mandatory(true) do
      form = address_form
      assert_select "label[for='address_phone_home']", text: "Home phone (required)"

      patch "#{BASE}/address", params: { address: form.merge("phone_home" => "", "phone_work" => "406-555-0199") }

      assert_response :unprocessable_content
      assert_select "#address-errors", text: /Home phone is required by this site/
    end
  end

  test "a home phone the site lists as not required saves without it" do
    with_home_phone_mandatory(false) do
      form = address_form
      assert_select "label[for='address_phone_home']", text: "Home phone (optional)"

      patch "#{BASE}/address", params: { address: form.merge("phone_home" => "", "phone_work" => "406-555-0198") }

      assert_redirected_to BASE
    end
  end

  # The build's own division requires PREFERRED LANGUAGE (#9000001) and lists
  # PRIMARY LANGUAGE as not required; read it rather than assume it.
  test "a preferred language the site requires is refused when missing, by name" do
    LiveRpmsSession.sign_on!
    parameters = RpmsRpc::RegistrationParameters.for_facility(facility)
    skip_reason = "the build's division does not require PREFERRED LANGUAGE: #{parameters[:mandatory_fields].inspect}"
    assert RpmsRpc::RegistrationParameters.required?(parameters, "9000001", "PREFERRED LANGUAGE"), skip_reason
    sign_in

    post "#{BASE}/languages", params: { languages: { primary_ien: SPANISH, interpreter: "Y" } }

    assert_response :unprocessable_content
    assert_select "#languages-errors", text: /Preferred language is required by this site/
  end
end
