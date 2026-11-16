# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_visit_helper"

# Live (rpms-ux S-TRI-02.1 to .3): on a real RPMS the scheduler checks the
# patient in, which files a visit; the medical assistant persona takes vitals
# from the chart, a PHQ-2 among them, and V MEASUREMENT (#9000010.01) is read
# back on that visit; a blood pressure of 400 is refused with RPMS's reason. It
# WRITES, so it runs only against a throwaway container and only when asked twice:
#
#   TZ=UTC LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9100 \
#   LIVE_RPMS_ACCESS=PMA123 LIVE_RPMS_VERIFY='PMA123!!' \
#   bin/rails test test/integration/live_vitals_test.rb
class LiveVitalsTest < ActionDispatch::IntegrationTest
  include LiveVisitHelper

  PATIENT = 3
  MEDICAL_ASSISTANT_DUZ = "204"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless live_writes?
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    next unless live_writes?

    ActionController::Base.allow_forgery_protection = @forgery_was
    LiveRpmsSession.sign_on!
  end

  test "S-TRI-02.1 S-TRI-02.2 S-TRI-02.3 the medical assistant takes vitals and a PHQ-2 on the visit check-in filed, and RPMS holds them there" do
    visit_ien = check_in_as_scheduler(PATIENT)
    warn "[live S-TRI-02] visit filed by check-in: #{visit_ien}"
    sign_in("PMA123", "PMA123!!")
    open_chart(PATIENT)
    assert_select "a[href='/lakeraven-ehr/patients/#{PATIENT}/vitals/new']", text: "Take vitals"

    post_vitals(visit_ien, "BP" => "400/80")
    assert_response :unprocessable_entity
    assert_match "Systolic pressure must be between 20 and 275 mmHg.", response.body
    assert_empty measurements_on(visit_ien), "a refused value files nothing"

    entered = { "HT" => "70", "WT" => "169", "BP" => "117/77", "PU" => "80", "RS" => "20", "TMP" => "98.7", "PHQ2" => "2" }
    post_vitals(visit_ien, entered)
    assert_response :redirect, css_select("[role='alert']").map(&:text).join(" ").squish
    follow_redirect!
    assert_match "Vitals recorded on the visit.", response.body

    filed = measurements_on(visit_ien)
    warn "[live S-TRI-02] V MEASUREMENT on visit #{visit_ien}: #{filed.map { |m| m.values_at(:measurement_ien, :type, :value) }.inspect}"
    # RPMS works out the BMI from the height and weight and files it too.
    bmi, typed = filed.partition { |m| m[:type] == "BMI" }
    assert_equal entered.sort, typed.map { |m| [ m[:type], m[:value] ] }.sort
    assert_equal 1, bmi.size, "RPMS filed the BMI it derived"
    row = ciav { RpmsRpc::DdrFileman.gets_entry(file: "9000010.01", iens: "#{filed.first[:measurement_ien]},", fields: ".02;.03;1204", flags: "I") }[:fields]
    assert_equal [ PATIENT.to_s, visit_ien, MEDICAL_ASSISTANT_DUZ ], %w[.02 .03 1204].map { |f| row.dig(f, :internal).to_s },
                 "patient, the check-in's visit, and PROFILE,MA as the encounter provider"
  end

  private

  def post_vitals(visit_ien, values)
    get "/lakeraven-ehr/patients/#{PATIENT}/vitals/new"
    assert_includes css_select("input[name='visit_ien']").map { |i| i["value"] }, visit_ien, "the checked-in visit is offered"
    post "/lakeraven-ehr/patients/#{PATIENT}/vitals", params: { visit_ien: visit_ien, vitals: values, authenticity_token: csrf }
  end

  # The visit's V MEASUREMENT entries (BGOVMSR GET; an empty reply is none).
  def measurements_on(visit_ien)
    Array(ciav { RpmsRpc::Measurement.for_visit(visit_ien) }).reject { |m| m[:entered_in_error] }
  end
end
