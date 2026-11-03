# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"

# Live (rpms-ux S-REG-08): the front-desk persona records a patient's
# emergency contact and next of kin on a real RPMS, and FileMan is
# read back to prove each landed. It WRITES, so it runs only against a throwaway
# container and only when asked twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9143 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_contacts_test.rb
class LiveRegistrationContactsTest < ActionDispatch::IntegrationTest
  DFN = 990_009 # INDIA,QUINN, a synthetic seed patient
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  # FileMan's internal values, read over DDR GETS ENTRY DATA as the run's persona.
  def fileman(file, iens, fields)
    LiveRpmsSession.sign_on!
    reply = RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: fields, flags: "I")
    assert reply && !reply[:error], "no #{file} entry #{iens}"
    reply[:fields].transform_values { |value| value[:internal] }
  end

  def picked(path, search, attribute, params = {})
    post path, params: params.merge(search)
    assert_response :ok
    css_select("label[data-#{attribute}] input").first&.[]("value")
  end

  test "S-REG-08.1 and S-REG-08.2 the emergency contact files to PATIENT and a new name clears the old address" do
    edit = "#{BASE}/contacts/emergency/edit"
    spouse = picked(edit, { relationship_search: "SPOUSE" }, "relationship")
    assert spouse, "RPMS listed no SPOUSE relationship"

    post "#{BASE}/contacts/emergency", params: { contact: { name: "LIVE,CONTACT", relationship_ien: spouse, address_line1: "1 TEST ST",
                                                            city: "ANYTOWN", zip: "12345", phone: "555-555-0100" } }
    assert_redirected_to "#{BASE}/contacts"
    assert_equal({ ".331" => "LIVE,CONTACT", ".333" => "1 TEST ST", ".336" => "ANYTOWN", ".339" => "555-555-0100" },
                 fileman("2", "#{DFN},", ".331;.333;.336;.339"))
    assert_equal spouse, fileman("9000001", "#{DFN},", "3102")["3102"]

    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
    post "#{BASE}/contacts/emergency", params: { contact: { name: "OTHER,PERSON", relationship_ien: spouse, address_line1: "1 TEST ST",
                                                            city: "ANYTOWN", zip: "12345", phone: "555-555-0100" } }
    assert_redirected_to "#{BASE}/contacts"
    assert_equal({ ".331" => "OTHER,PERSON", ".333" => "", ".336" => "", ".339" => "" }, fileman("2", "#{DFN},", ".331;.333;.336;.339"))
  end

  test "S-REG-08.3 RPMS's own name check refuses a doubled hyphen, and nothing is filed" do
    before = fileman("2", "#{DFN},", ".211")[".211"]
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }

    post "#{BASE}/contacts/next_of_kin", params: { contact: { name: "LIVE--X,KIN" } }

    assert_response :unprocessable_content
    assert_select "#contact-alert", text: /Name is not in correct format/
    assert_equal before, fileman("2", "#{DFN},", ".211")[".211"]
  end
end
