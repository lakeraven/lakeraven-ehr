# frozen_string_literal: true

require "test_helper"
require "open3"
require "socket"

# End to end for `cucumber --profile stack` (#962): one @live scenario, run as
# a subprocess, three ways. A stack run that cannot reach its stack reports the
# scenario as not run and never as passed; without LIVE_STACK the scenario
# still passes on the mock. Every code here is synthetic.
class LiveStackCucumberTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)
  FEATURE = "features/patient_search.feature"
  SCENARIO = "Scenario: Search with no results"
  ACCESS = "SYNTH1"
  VERIFY = "SYNTH1!!"

  # Nothing of the caller's environment may bind or unbind the run.
  CLEARED = %w[
    LIVE_STACK LIVE_RPMS RPMS_IP RPMS_PORT RPMS_BROKER RPMS_ACCESS RPMS_VERIFY
    LIVE_RPMS_ACCESS LIVE_RPMS_VERIFY RPMS_UCI VISTA_RPC_HOST VISTA_RPC_PORT VISTA_BROKER
  ].to_h { |name| [ name, nil ] }.freeze

  def scenario_location
    line = File.readlines(File.join(ROOT, FEATURE)).index { |text| text.strip == SCENARIO }
    assert line, "#{SCENARIO.inspect} not found in #{FEATURE}"
    "#{FEATURE}:#{line + 1}"
  end

  def cucumber(*arguments, env: {})
    Open3.capture2e(
      CLEARED.merge("RAILS_ENV" => "test").merge(env),
      "bundle", "exec", "cucumber", *arguments, scenario_location,
      chdir: ROOT
    )
  end

  def closed_local_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def assert_skipped_not_passed(output)
    assert_match(/^1 scenario \(1 skipped\)$/, output, "expected the one scenario skipped:\n#{output}")
    assert_no_match(/\d+ passed/, output, "a scenario or step passed:\n#{output}")
    assert_no_match(/\bfailed\b/, output, "a scenario or step failed:\n#{output}")
  end

  # #1179: a stack run in which no @live scenario ran is not a green run. It
  # exits non-zero and says so in one line, naming the first not-run reason.
  def assert_nothing_ran(output, status, reason:)
    assert_not_equal 0, status.exitstatus, "a stack run with no @live scenario run exited 0:\n#{output}"
    assert_equal 1, output.scan(/^\[stack\] no @live scenario ran: /).size,
                 "expected one line saying no @live scenario ran:\n#{output}"
    assert_match(/^\[stack\] no @live scenario ran: .*#{reason}/, output,
                 "expected the line to name #{reason.inspect}:\n#{output}")
    assert_not_includes output, VERIFY, "the verify code leaked into the run's output"
    assert_not_includes output, ACCESS, "the access code leaked into the run's output"
  end

  # No RPMS_IP: the binding is incomplete, whatever codes the run carries.
  NO_BINDING = { "RPMS_ACCESS" => ACCESS, "RPMS_VERIFY" => VERIFY }.freeze

  test "a stack run with no binding skips the scenario, says what is missing and exits non-zero" do
    output, status = cucumber("--profile", "stack", env: NO_BINDING)

    assert_nothing_ran output, status, reason: "missing.*RPMS_IP"
    assert_includes output, "not run:"
    assert_skipped_not_passed output
  end

  test "a stack run that cannot reach its broker reports not run, never passed, and exits non-zero" do
    output, status = cucumber("--profile", "stack", env: {
      "RPMS_IP" => "127.0.0.1", "RPMS_PORT" => closed_local_port.to_s, "RPMS_BROKER" => "cia",
      "RPMS_ACCESS" => ACCESS, "RPMS_VERIFY" => VERIFY
    })

    assert_nothing_ran output, status, reason: "broker unreachable"
    assert_includes output, "not run:"
    assert_skipped_not_passed output
  end

  # None selected is none run: the reason is why the stack was not ready.
  test "a stack run that selects no scenario exits non-zero and names why the stack was not ready" do
    output, status = cucumber("--profile", "stack", "--tags", "@live and @no_such_tag_1179", env: NO_BINDING)

    assert_match(/^0 scenarios$/, output, "expected no scenario selected:\n#{output}")
    assert_nothing_ran output, status, reason: "missing.*RPMS_IP"
  end

  test "without LIVE_STACK the scenario still passes on the mock" do
    output, status = cucumber

    assert_equal 0, status.exitstatus, "expected exit 0:\n#{output}"
    assert_match(/^1 scenario \(1 passed\)$/, output, "expected the one scenario passed:\n#{output}")
    assert_not_includes output, "not run:"
    assert_not_includes output, "no @live scenario ran"
  end
end
