# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_visit_helper"

# Live (rpms-ux S-TRI-04.1): on a real RPMS the scheduler checks the patient
# in, which files a visit; the medical assistant persona marks the allergies
# reviewed on that visit from the chart, and V UPDATED/REVIEWED (#9000010.54)
# is read back with FileMan. It WRITES, so it runs only against a throwaway
# container and only when asked twice:
#
#   TZ=UTC LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9100 \
#   LIVE_RPMS_ACCESS=PMA123 LIVE_RPMS_VERIFY='PMA123!!' \
#   bin/rails test test/integration/live_allergy_review_test.rb
class LiveAllergyReviewTest < ActionDispatch::IntegrationTest
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

  test "S-TRI-04.1 the medical assistant marks the allergies reviewed on the visit check-in filed, and RPMS holds the review there" do
    visit_ien = check_in_as_scheduler(PATIENT)
    warn "[live S-TRI-04.1] visit filed by check-in: #{visit_ien}"
    sign_in("PMA123", "PMA123!!")
    open_chart(PATIENT)
    assert_select "a[href='/lakeraven-ehr/patients/#{PATIENT}/allergy_reviews/new']", text: "Mark allergies reviewed"
    get "/lakeraven-ehr/patients/#{PATIENT}/allergy_reviews/new"
    assert_includes css_select("input[name='visit_ien']").map { |i| i["value"] }, visit_ien, "the checked-in visit is offered"

    post "/lakeraven-ehr/patients/#{PATIENT}/allergy_reviews", params: { visit_ien: visit_ien, authenticity_token: csrf }
    assert_response :redirect, css_select("[role='alert']").map(&:text).join(" ").squish
    follow_redirect!
    assert_match "Allergies marked reviewed on the visit.", response.body

    LiveRpmsSession.sign_on!
    review = ciav { RpmsRpc::ClinicalReview.for_visit(PATIENT, visit_ien) }.find { |r| r[:action].to_s.end_with?("ALLERGY LIST REVIEWED") }
    flunk "BGOVUPD GET on visit #{visit_ien} lists no ALLERGY LIST REVIEWED" unless review
    row = ciav { RpmsRpc::DdrFileman.gets_entry(file: "9000010.54", iens: "#{review[:ien]},", fields: ".01;.02;.03;1.02", flags: "IE") }[:fields]
    warn "[live S-TRI-04.1] #9000010.54 #{review[:ien]}: #{row.inspect}"
    assert_equal "ALLERGY LIST REVIEWED", row.dig(".01", :external)
    assert_equal [ PATIENT.to_s, visit_ien, MEDICAL_ASSISTANT_DUZ ], %w[.02 .03 1.02].map { |f| row.dig(f, :internal).to_s },
                 "the patient, the check-in's visit, entered by PROFILE,MA"
  end
end
