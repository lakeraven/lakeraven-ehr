# frozen_string_literal: true

require "test_helper"
require "open3"

# End to end for the READY path of `cucumber --profile stack` (#962), without a
# broker: the repo's real hooks (features/support/live_stack.rb and
# gateway_stubs.rb) loaded by the self-contained cucumber project in
# test/fixtures/live_stack_ready over a fake client. One scenario per run. Only
# a scenario with evidence that it ran against the stack as the persona is
# reported passed; every other is skipped as not run, and says why.
class LiveStackReadyCucumberTest < ActiveSupport::TestCase
  PROJECT = File.expand_path("../fixtures/live_stack_ready", __dir__)

  # Nothing of the caller's environment may bind the run or reach Rails.
  CLEARED = %w[
    LIVE_STACK LIVE_RPMS RPMS_IP RPMS_PORT RPMS_BROKER RPMS_ACCESS RPMS_VERIFY
    LIVE_RPMS_ACCESS LIVE_RPMS_VERIFY RPMS_UCI VISTA_RPC_HOST VISTA_RPC_PORT VISTA_BROKER
  ].to_h { |name| [ name, nil ] }.freeze

  def cucumber(*scenarios, options: [])
    names = scenarios.flat_map { |scenario| [ "--name", "^#{Regexp.escape(scenario)}$" ] }
    Open3.capture2e(CLEARED, "bundle", "exec", "cucumber", "--publish-quiet", *options, *names, chdir: PROJECT)
  end

  NO_SCENARIO_RAN = /^\[stack\] no @live scenario ran: (.*)$/

  # #1179: no scenario ran, so the run is not green and says so in one line.
  # Returns what the line names.
  def assert_no_scenario_ran(output, status)
    assert_not_equal 0, status.exitstatus, "a stack run with no scenario run exited 0:\n#{output}"
    lines = output.scan(NO_SCENARIO_RAN).flatten
    assert_equal 1, lines.size, "expected one line saying no @live scenario ran:\n#{output}"
    lines.first
  end

  def assert_not_run(scenario, reason:)
    output, status = cucumber(scenario)

    # #1179: the one scenario was not run, so no scenario ran: not a green run.
    assert_not_equal 0, status.exitstatus, "a stack run with no scenario run exited 0:\n#{output}"
    assert_equal 1, output.scan(/^\[stack\] no @live scenario ran: /).size,
                 "expected one line saying no @live scenario ran:\n#{output}"
    assert_match(/^\[stack\] no @live scenario ran: .*#{Regexp.escape(reason)}/, output,
                 "expected the line to name #{reason.inspect}:\n#{output}")
    assert_match(/^1 scenario \(1 skipped\)$/, output, "expected the one scenario skipped:\n#{output}")
    assert_includes output, "not run:", "the run did not say why:\n#{output}"
    assert_match(/not run: .*#{Regexp.escape(reason)}/, output, "expected the reason to name #{reason.inspect}:\n#{output}")
    # The step that ran stays counted as passed: the verdict skips the scenario
    # from the last step's AfterStep. Only the scenario line is judged.
    assert_no_match(/\d+ scenarios? \([^)]*passed/, output, "a scenario passed:\n#{output}")
    assert_no_match(/\bfailed\b/, output, "a scenario or step failed:\n#{output}")
  end

  test "a scenario the persona read from the stack in is passed" do
    output, status = cucumber("The persona reads from the stack")

    assert_equal 0, status.exitstatus, "expected exit 0:\n#{output}"
    assert_match(/^1 scenario \(1 passed\)$/, output, "expected the one scenario passed:\n#{output}")
    assert_not_includes output, "not run:"
    assert_not_includes output, "no @live scenario ran"
  end

  # #1179: one scenario ran, so the exit code is cucumber's own.
  test "a run in which one scenario passed and another was not run keeps cucumber's exit 0" do
    output, status = cucumber("The persona reads from the stack", "Nothing is read")

    assert_equal 0, status.exitstatus, "expected exit 0:\n#{output}"
    assert_match(/^2 scenarios \(1 skipped, 1 passed\)$/, output, "expected one passed, one skipped:\n#{output}")
    assert_match(/not run: .*no RPC reached the stack/, output)
    assert_not_includes output, "no @live scenario ran"
  end

  test "a run whose one scenario ran and failed keeps cucumber's failing exit" do
    output, status = cucumber("The persona reads from the stack and a check fails")

    assert_equal 1, status.exitstatus, "expected cucumber's exit 1:\n#{output}"
    assert_match(/^1 scenario \(1 failed\)$/, output, "expected the one scenario failed:\n#{output}")
    assert_not_includes output, "no @live scenario ran"
  end

  test "a scenario that read nothing is not run" do
    assert_not_run "Nothing is read", reason: "no RPC reached the stack"
  end

  test "a scenario whose RPC the stack refused is not run" do
    assert_not_run "The stack refuses an RPC", reason: "ORWPT LIST ALL"
  end

  test "a scenario that swallowed a refused RPC is not run" do
    assert_not_run "The app swallows a refused RPC", reason: "ORWPT LIST ALL"
  end

  test "a scenario answered by another client is not run" do
    assert_not_run "Another client answers", reason: "not the persona's client"
  end

  test "a scenario whose client signed on as someone else is not run" do
    assert_not_run "The client signs on as someone else", reason: "not the persona's client"
  end

  test "a scenario with a stubbed gateway is not run" do
    assert_not_run "A gateway is stubbed", reason: "gateway"
  end

  # Stubbed with a bare define_singleton_method, which @gateway_stubs never
  # sees: LiveStack::StubWatch on Module is what reports it.
  test "a scenario with a gateway stubbed bare is not run" do
    assert_not_run "A gateway is stubbed bare", reason: "a gateway was stubbed: LiveStackReady::ThrowawayGateway.find"
  end

  # The real RpmsStandIn::Connection, watched by LiveStack.install!'s default.
  test "a scenario the mock answered through call_rpc_lines is not run" do
    assert_not_run "The mock answers through its lines", reason: "ORWPT LIST ALL was answered by the mock"
  end

  test "a scenario the mock answered through call_rpc_global_array is not run" do
    assert_not_run "The mock answers through its global array", reason: "ORWPT LIST ALL was answered by the mock"
  end

  # travel_to, travel and freeze_time stub Time.now, Date.today and DateTime.now
  # through ActiveSupport's SimpleStubs, watched by LiveStack.install!'s default.
  test "a scenario that moved the clock and read from the stack is passed" do
    output, status = cucumber("The clock is moved")

    assert_equal 0, status.exitstatus, "expected exit 0:\n#{output}"
    assert_match(/^1 scenario \(1 passed\)$/, output, "expected the one scenario passed:\n#{output}")
    assert_not_includes output, "not run:"
    assert_not_includes output, "no @live scenario ran"
  end

  test "a scenario that moved the clock and stubbed a gateway bare is not run, and names the gateway" do
    assert_not_run "The clock is moved and a gateway is stubbed bare",
                   reason: "a gateway was stubbed: LiveStackReady::ThrowawayGateway.find"
  end

  # The mock raised, so it answered nothing, but the scenario still reached it.
  test "a scenario that swallowed an error from the mock is not run" do
    assert_not_run "The app swallows an error from the mock", reason: "ORWPT LIST ALL was answered by the mock"
  end

  # #1179 round 2: only a scenario that passed or failed ran. A pending or
  # undefined scenario produced no evidence, and cucumber is not strict.
  test "a run whose one scenario is pending is not a green run" do
    output, status = cucumber("A step is pending")

    assert_match(/^1 scenario \(1 pending\)$/, output, "expected the one scenario pending:\n#{output}")
    assert_includes assert_no_scenario_ran(output, status), "pending or undefined", output
  end

  test "a run whose one scenario has an undefined step is not a green run" do
    output, status = cucumber("A step has no definition")

    assert_match(/^1 scenario \(1 undefined\)$/, output, "expected the one scenario undefined:\n#{output}")
    assert_includes assert_no_scenario_ran(output, status), "pending or undefined", output
  end

  # "Nothing is read" comes first in the feature, so its reason is the first.
  test "a run of a scenario not run and then a pending one names the first reason" do
    output, status = cucumber("Nothing is read", "A step is pending")

    assert_match(/^2 scenarios \(1 skipped, 1 pending\)$/, output, "expected one skipped, one pending:\n#{output}")
    line = assert_no_scenario_ran(output, status)
    assert_includes line, "no RPC reached the stack", output
    assert_not_includes line, "pending or undefined", output
  end

  # The last attempt of a scenario decides: the retry was not run.
  test "a retried scenario whose last attempt was not run is not a green run" do
    output, status = cucumber("The first attempt fails and the second reads nothing", options: %w[--retry 1])

    assert_includes output, "the first attempt failed", "the first attempt did not fail:\n#{output}"
    assert_match(/not run: .*no RPC reached the stack/, output, "the second attempt was run:\n#{output}")
    assert_includes assert_no_scenario_ran(output, status), "no RPC reached the stack", output
  end

  # Selected, and skipped by its own step with no recorded reason.
  test "a run whose one scenario skipped itself does not say none was selected" do
    output, status = cucumber("A step skips the scenario itself")

    assert_match(/^1 scenario \(1 skipped\)$/, output, "expected the one scenario skipped:\n#{output}")
    assert_not_includes assert_no_scenario_ran(output, status), "was selected", output
  end

  test "a ready run that selected no scenario says so" do
    output, status = cucumber("No scenario has this name")

    assert_match(/^0 scenarios$/, output, "expected no scenario selected:\n#{output}")
    assert_includes assert_no_scenario_ran(output, status), "no @live scenario was selected", output
  end
end
