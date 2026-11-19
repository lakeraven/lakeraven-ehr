# frozen_string_literal: true

require "test_helper"
require "capybara/cuprite"

# rpms-ux S-REG-02 (#975): the new-patient form says which fields RPMS needs
# before it is refused, and its refusal names them in a clerk's words.
#
# A real browser against the app on the mocked broker (test_helper), signing
# in through the form as a clerk holding AGZMENU. CI runs these by path:
#
#   bin/rails test test/system/*_test.rb
#
# Screenshots land in REGISTRATION_EVIDENCE_DIR (default
# tmp/evidence/registration_required_fields).
class RegistrationRequiredFieldsTest < ActionDispatch::SystemTestCase
  driven_by :cuprite, screen_size: [ 1280, 1400 ], options: { headless: true, process_timeout: 30 }

  EVIDENCE_DIR = Pathname.new(
    ENV.fetch("REGISTRATION_EVIDENCE_DIR") { File.expand_path("../../tmp/evidence/registration_required_fields", __dir__) }
  )

  setup do
    Lakeraven::EHR::LoginThrottle.reset!
    mock = RpmsRpc.client
    mock.seed_user("975", credentials: "regclerk;test123", name: "CLERK,REGISTRATION", role: :clerk)
    mock.seed_held_keys("975", [ "AGZMENU" ])
    mock.seed_options("975", [ "CIAV VUECENTRIC" ])
  end

  test "tribe and community are marked required, and a form without them says so without 'ien'" do
    visit "/lakeraven-ehr/login"
    fill_in "Access code", with: "regclerk"
    fill_in "Verify code", with: "test123"
    click_on "Sign in"
    assert_selector "h1", text: "Dashboard"

    visit "/lakeraven-ehr/registration/patients/new"
    assert_selector "h1", text: "Register a new patient"
    assert_selector "#registration-form legend", text: "Tribe of membership (required)"
    assert_selector "#registration-form legend", text: "Community of residence (required)"
    evidence "1-form"

    fill_in "Name (LAST,FIRST MIDDLE)", with: "TEST,DEMOWALK"
    choose "Female"
    fill_in "Date of birth", with: Date.new(1990, 5, 1)
    select "No SSN assigned", from: "Or, the reason there is none"
    click_on "Register"

    assert_selector "#registration-errors", text: "The registration was not saved."
    evidence "2-refused"
    messages = all("#registration-errors li").map(&:text)
    assert_includes messages, "Tribe of membership is required"
    assert_includes messages, "Community of residence is required"
    assert messages.none? { |m| m.match?(/\bien\b/i) }, "a message names the FileMan pointer: #{messages.inspect}"
  end

  private

  def evidence(step)
    FileUtils.mkdir_p(EVIDENCE_DIR)
    page.save_screenshot(EVIDENCE_DIR.join("#{step}.png").to_s, full: true)
  end
end
