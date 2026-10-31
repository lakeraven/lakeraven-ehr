# frozen_string_literal: true

require "test_helper"

# RpmsSessions refuses to serve per-user RPMS connections from more than one
# server process: a request routed to a process that does not hold its user's
# connection would sign them out (ADR 0011 §5).
class RpmsSessionsTest < ActiveSupport::TestCase
  test "one process boots" do
    assert_nil Lakeraven::EHR::RpmsSessions.assert_single_process!(workers: 0)
    assert_nil Lakeraven::EHR::RpmsSessions.assert_single_process!(workers: 1)
  end

  test "more than one worker process refuses to boot" do
    error = assert_raises(Lakeraven::EHR::RpmsSessions::MultipleProcesses) do
      Lakeraven::EHR::RpmsSessions.assert_single_process!(workers: 2)
    end
    assert_match(/one Puma process/, error.message)
  end

  test "WEB_CONCURRENCY counts as workers" do
    previous = ENV["WEB_CONCURRENCY"]
    ENV["WEB_CONCURRENCY"] = "3"
    assert_equal 3, Lakeraven::EHR::RpmsSessions.puma_workers
  ensure
    ENV["WEB_CONCURRENCY"] = previous
  end
end
