# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_visit_helper"

# Live (rpms-ux S-TRI-07.1): on a real RPMS the scheduler checks the patient
# in, which files a visit; the medical assistant persona opens the chart,
# records the chief complaint on that visit, and V NARRATIVE TEXT
# (#9000010.34) is read back with FileMan. It WRITES, so it runs only against
# a throwaway container and only when asked twice:
#
#   TZ=UTC LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9100 \
#   LIVE_RPMS_ACCESS=PMA123 LIVE_RPMS_VERIFY='PMA123!!' \
#   bin/rails test test/integration/live_chief_complaint_test.rb
class LiveChiefComplaintTest < ActionDispatch::IntegrationTest
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

  test "S-TRI-07.1 the medical assistant records the chief complaint on the visit check-in filed, and RPMS holds it there" do
    visit_ien = check_in_as_scheduler(PATIENT)
    warn "[live S-TRI-07.1] visit filed by check-in: #{visit_ien}"

    sign_in("PMA123", "PMA123!!")
    open_chart(PATIENT)
    assert_select "a[href='/lakeraven-ehr/patients/#{PATIENT}/chief_complaints/new']", text: "Record chief complaint"
    get "/lakeraven-ehr/patients/#{PATIENT}/chief_complaints/new"
    assert_includes css_select("input[name='visit_ien']").map { |i| i["value"] }, visit_ien, "the checked-in visit is offered"

    text = "Joint pain and nausea for 4 days #{Time.now.utc.strftime('%H%M%S')}"
    post "/lakeraven-ehr/patients/#{PATIENT}/chief_complaints",
         params: { visit_ien: visit_ien, chief_complaint: text, authenticity_token: csrf }
    assert_response :redirect, css_select("[role='alert']").map(&:text).join(" ").squish
    follow_redirect!
    assert_match "Chief complaint recorded on the visit.", response.body

    LiveRpmsSession.sign_on!
    filed = ciav { RpmsRpc::ChiefComplaint.for_visit(visit_ien) }.find { |row| row[:text].end_with?(text) }
    flunk "BGOCC GET on visit #{visit_ien} lists no chief complaint ending #{text.inspect}" unless filed
    row = ciav { RpmsRpc::DdrFileman.gets_entry(file: "9000010.34", iens: "#{filed[:ien]},", fields: ".01;.02;.03;1204", flags: "IE") }[:fields]
    warn "[live S-TRI-07.1] #9000010.34 #{filed[:ien]}: #{row.inspect}"
    assert_equal "CHIEF COMPLAINT", row.dig(".01", :external)
    assert_equal PATIENT.to_s, row.dig(".02", :internal)
    assert_equal visit_ien, row.dig(".03", :internal), "filed on the visit check-in made"
    assert_equal MEDICAL_ASSISTANT_DUZ, row.dig("1204", :internal), "entered as PROFILE,MA"
  end
end
