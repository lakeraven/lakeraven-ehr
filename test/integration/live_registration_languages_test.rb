# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"

# Live (rpms-ux S-REG-10): the front-desk persona records a patient's
# languages on a real RPMS, and FileMan is
# read back to prove each landed. It WRITES, so it runs only against a throwaway
# container and only when asked twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9143 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_languages_test.rb
class LiveRegistrationLanguagesTest < ActionDispatch::IntegrationTest
  DFN = 990_009 # INDIA,QUINN, a synthetic seed patient
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze
  ENGLISH = 144
  SPANISH = 531

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

  test "S-REG-10.1 the languages file a new dated entry" do
    post "#{BASE}/languages", params: { languages: { primary_ien: SPANISH, interpreter: "Y", proficiency: "NW", preferred_ien: SPANISH,
                                                     others: [ ENGLISH ] } }
    assert_redirected_to "#{BASE}#languages-section"

    LiveRpmsSession.sign_on!
    latest = RpmsRpc::PatientProfile.languages(DFN)
    assert_equal SPANISH, latest.dig(:primary, :ien)
    # The newest LANGUAGES ENTRY DATE entry, read from FileMan.
    entries = (1..30).map do |ien|
      reply = RpmsRpc::DdrFileman.gets_entry(file: "9000001.86", iens: "#{ien},#{DFN},", fields: ".01;.02;.03;.06", flags: "I")
      reply && !reply[:error] ? reply[:fields].transform_values { |v| v[:internal] } : nil
    end.compact
    assert_equal({ ".02" => SPANISH.to_s, ".03" => "Y", ".06" => "NW" }, entries.last.except(".01"))
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
    get BASE
    assert_select "#languages-section [data-field='others']", text: "English"
  end
end
