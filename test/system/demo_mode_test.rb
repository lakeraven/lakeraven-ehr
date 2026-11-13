# frozen_string_literal: true

require "test_helper"
require "capybara/cuprite"

# The public demo (#952): with Configuration#demo_mode on (DEMO_MODE=1), every
# page says it is a test environment, and sign-in waits until the visitor
# accepts the demo's terms. With it off, neither appears.
#
# A real browser against the app on the mocked broker (test_helper), signing in
# through the form as a visitor does. `bin/rails test` leaves test/system out,
# so CI runs these by path:
#
#   bin/rails test test/system/*_test.rb
#
# Screenshots of each step land in DEMO_MODE_EVIDENCE_DIR (default
# tmp/evidence/demo_mode).
class DemoModeTest < ActionDispatch::SystemTestCase
  # Chrome on a busy CI runner can take longer than Ferrum's 10-second default to
  # report its websocket URL, which failed this test before it ran a step.
  driven_by :cuprite, screen_size: [ 1280, 900 ], options: { headless: true, process_timeout: 30 }

  BANNER = "Test environment. Synthetic data only. " \
           "Data may be reset at any time; anything you enter can be erased."

  EVIDENCE_DIR = Pathname.new(
    ENV.fetch("DEMO_MODE_EVIDENCE_DIR") { File.expand_path("../../tmp/evidence/demo_mode", __dir__) }
  )

  setup do
    Lakeraven::EHR::LoginThrottle.reset!
    @demo_mode_was = Lakeraven::EHR.configuration.demo_mode
  end

  teardown do
    Lakeraven::EHR.configuration.demo_mode = @demo_mode_was
  end

  test "with demo mode on, the banner is on the sign-in and signed-in pages, and sign-in waits for the terms" do
    Lakeraven::EHR.configuration.demo_mode = true

    visit "/lakeraven-ehr/login"
    evidence "on-1-terms"
    assert_banner
    assert_selector "h1", text: "Before you sign in"
    assert_selector "#demo-terms li", text: "It is a test system, with synthetic data only."
    assert_selector "#demo-terms li", text: "Never enter real patient information."
    assert_selector "#demo-terms li", text: "No promise of uptime or of keeping data."
    assert_selector "#demo-terms a[href='https://github.com/afomi/open-rpms-website/issues']", text: "Open an issue"
    assert_selector "a[href='https://openrpms.org/demo']", text: "Read the full terms of use"
    assert_no_field "Access code"

    click_on "I accept these terms"
    evidence "on-2-sign-in"
    assert_banner
    assert_selector "h1", text: "Sign in"

    sign_in_as_provider
    evidence "on-3-dashboard"
    assert_selector "h1", text: "Dashboard"
    assert_banner

    visit "/lakeraven-ehr/patients/1"
    evidence "on-4-chart"
    assert_banner

    # Accepted for the browser session: signing out and back in asks again for nothing.
    visit "/lakeraven-ehr/dashboard"
    click_on "Sign out"
    assert_selector "h1", text: "Sign in"
    assert_banner
  end

  test "with demo mode off, there is no banner and no terms to accept" do
    Lakeraven::EHR.configuration.demo_mode = false

    visit "/lakeraven-ehr/login"
    evidence "off-1-sign-in"
    assert_selector "h1", text: "Sign in"
    assert_no_selector "#demo-banner"
    assert_no_text "Test environment"
    assert_no_text "Before you sign in"

    sign_in_as_provider
    evidence "off-2-dashboard"
    assert_selector "h1", text: "Dashboard"
    assert_no_selector "#demo-banner"
    assert_no_text "Test environment"
  end

  private

  # The banner is a labelled region, so it is among the page's landmarks, and
  # it comes first in the page, so a screen reader reaches it before anything else.
  def assert_banner
    assert_selector "[role=region][aria-label='Test environment']", text: BANNER, exact_text: true
    first_in_body = page.evaluate_script("document.body.firstElementChild.id")
    assert_equal "demo-banner", first_in_body, "the banner must be the first thing in the page"
  end

  def sign_in_as_provider
    fill_in "Access code", with: "testprovider"
    fill_in "Verify code", with: "test123"
    click_on "Sign in"
  end

  def evidence(step)
    FileUtils.mkdir_p(EVIDENCE_DIR)
    page.save_screenshot(EVIDENCE_DIR.join("#{step}.png").to_s, full: true)
  end
end
