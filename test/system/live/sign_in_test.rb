# frozen_string_literal: true

require_relative "live_system_test_case"

# A clinician signs in with their RPMS access and verify codes and lands on the
# dashboard, against a live broker (#539). Screenshots of each step land in
# LIVE_EVIDENCE_DIR.
class LiveSignInTest < LiveSystemTestCase
  test "a clinician signs in with RPMS codes and lands on the dashboard" do
    visit "/lakeraven-ehr/login"
    evidence "1-sign-in-form"

    sign_in ENV.fetch("LIVE_RPMS_ACCESS"), ENV.fetch("LIVE_RPMS_VERIFY")
    evidence "2-after-sign-in"

    assert_selector "h1", text: "Dashboard"
    assert_text(/Signed in as \S+,\S+/)
  end

  # No live "wrong verify code" case on purpose: RPMS counts failed sign-ons
  # against the connecting address and locks it out, which would take down
  # every other user of the same broker. The mocked suite covers rejection.

  # An account RPMS has flagged for a verify-code change gets no session: the
  # app refuses it the way CPRS forces the change first. Needs such an account
  # on the target (a freshly built image's SYS123 is one).
  test "an account flagged for a verify-code change is refused" do
    skip "set LIVE_RPMS_FLAGGED_ACCESS / LIVE_RPMS_FLAGGED_VERIFY" unless ENV["LIVE_RPMS_FLAGGED_ACCESS"]

    sign_in ENV.fetch("LIVE_RPMS_FLAGGED_ACCESS"), ENV.fetch("LIVE_RPMS_FLAGGED_VERIFY")
    evidence "verify-change-refused"

    assert_selector "[role=alert]", text: "Your verify code must be changed"
    assert_no_selector "h1", text: "Dashboard"
  end
end
