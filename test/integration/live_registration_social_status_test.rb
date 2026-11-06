# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"

# Live (rpms-ux S-REG-11, S-REG-31.3): the front-desk persona answers the
# migrant, homeless and internet questions on a real RPMS, FileMan is read back
# to prove each landed dated today, and AG stops warning about them. It WRITES,
# so it runs only against a throwaway container and only when asked twice:
# LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9143 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_social_status_test.rb
class LiveRegistrationSocialStatusTest < ActionDispatch::IntegrationTest
  DFN = 990_010 # a synthetic seed patient
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze
  WARNINGS = %w[37 39 40].freeze # internet, migrant, homeless

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  # The newest entry of a dated multiple, internal values, over DDR as the run's persona.
  def latest(file, fields)
    LiveRpmsSession.sign_on!
    listed = RpmsRpc::DdrFileman.lister(file: file, iens: ",#{DFN},", fields: "@;.01I", flags: "IP")
    iens = listed[:entries].map { |entry| entry[:ien].to_i }.max
    assert iens, "no entry in #{file}"
    reply = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{iens},#{DFN},", fields: fields, flags: "I")
    reply[:fields].transform_values { |value| value[:internal] }
  end

  test "S-REG-11.1, 11.2 and S-REG-31.3 each answer is on file dated today, and no warning stays" do
    post "#{BASE}/social_status", params: { social_status: { migrant: "Y", migrant_type: "S", homeless: "Y", homeless_type: "T", internet: "Y" } }
    assert_redirected_to "#{BASE}#social-status-section"

    today = (Date.current.year - 1700).to_s + Date.current.strftime("%m%d")
    assert_equal({ ".01" => today, ".02" => "Y", ".03" => "S" }, latest("9000001.84", ".01;.02;.03"))
    assert_equal({ ".01" => today, ".02" => "Y", ".03" => "T" }, latest("9000001.85", ".01;.02;.03"))
    assert_equal({ ".01" => today, ".02" => "1" }, latest("9000001.81", ".01;.02"))

    warned = RpmsRpc::Agg.edit_check(dfn: DFN)[:checks].map { |check| check[:hide_error_num] }
    assert_empty WARNINGS & warned, "AG still warns: #{warned}"

    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
    get BASE
    assert_select "#social-status-section [data-field='homeless']", text: /Yes, Transitional/
    assert_select "#missing-items li[data-check='40']", count: 0
  end

  test "S-REG-11.4 a no files without a type" do
    post "#{BASE}/social_status", params: { social_status: { homeless: "Y", homeless_type: "S" } }
    assert_redirected_to "#{BASE}#social-status-section"
    post "#{BASE}/social_status", params: { social_status: { homeless: "N", homeless_type: "S" } }
    assert_redirected_to "#{BASE}#social-status-section"

    LiveRpmsSession.sign_on!
    status = RpmsRpc::PatientProfile.social_status(DFN)
    assert_equal "N", status.dig(:homeless, :status)
    assert_nil status.dig(:homeless, :type)
  end
end
