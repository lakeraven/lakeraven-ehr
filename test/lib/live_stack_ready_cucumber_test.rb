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

  def cucumber(scenario)
    Open3.capture2e(
      CLEARED, "bundle", "exec", "cucumber", "--publish-quiet", "--name", "^#{Regexp.escape(scenario)}$",
      chdir: PROJECT
    )
  end

  def assert_not_run(scenario, reason:)
    output, status = cucumber(scenario)

    assert_equal 0, status.exitstatus, "expected exit 0:\n#{output}"
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
end
