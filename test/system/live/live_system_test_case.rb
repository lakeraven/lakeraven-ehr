# frozen_string_literal: true

# Live system tests: a real browser against a real RPMS broker.
#
# Everything else in this suite runs against RpmsRpc.mock! (test_helper.rb).
# These tests deliberately do NOT load test_helper, so the broker client is the
# one the engine builds from the environment at boot (#539) — the same path a
# deployed app takes. Run them on their own, never alongside the mocked suite:
#
#   LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=19200 \
#   LIVE_RPMS_ACCESS=... LIVE_RPMS_VERIFY=... \
#   bin/rails test test/system/live
#
# The staging test account PROV123 is refused by rpms-rpc outside Rails
# development (its debug-credential guard), and `bin/rails test` forces the
# test environment. For PROV123, run the file directly instead:
#
#   RAILS_ENV=development LIVE_RPMS=1 ... bundle exec ruby -Itest test/system/live/sign_in_test.rb
#
# Each step saves a screenshot under LIVE_EVIDENCE_DIR (default
# tmp/evidence/live/<timestamp>), so a run leaves evidence of what the
# clinician saw, not only a pass/fail line.
ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"
require "rails/test_help"
require "capybara/cuprite"

class LiveSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :cuprite, screen_size: [ 1280, 900 ], options: { headless: true }

  EVIDENCE_DIR = Pathname.new(
    ENV.fetch("LIVE_EVIDENCE_DIR") do
      File.expand_path("../../../tmp/evidence/live/#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}", __dir__)
    end
  )

  setup do
    skip "live RPMS test: set LIVE_RPMS=1 and point VISTA_RPC_HOST at a broker" unless ENV["LIVE_RPMS"] == "1"

    Lakeraven::EHR::LoginThrottle.reset!
  end

  private

  # Save what the browser shows right now, named for the step it proves.
  def evidence(step)
    FileUtils.mkdir_p(EVIDENCE_DIR)
    page.save_screenshot(EVIDENCE_DIR.join("#{name}-#{step}.png").to_s, full: true)
  end

  def sign_in(access_code, verify_code)
    visit "/lakeraven-ehr/login"
    fill_in "Access code", with: access_code
    fill_in "Verify code", with: verify_code
    click_on "Sign in"
  end
end
