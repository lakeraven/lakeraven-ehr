# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class GpraReportJobTest < ActiveJob::TestCase
      teardown { Lakeraven::EHR.configuration.gpra_source = nil }

      test "does nothing until the site configures a source" do
        Lakeraven::EHR.configuration.gpra_source = nil
        GpraReportJob.perform_now

        assert_equal 0, GpraRun.count
      end

      test "computes a run from the configured source" do
        Lakeraven::EHR.configuration.gpra_source = Gpra::NdjsonDirectorySource.new(file_fixture("gpra_population").to_s)
        GpraReportJob.perform_now

        assert GpraRun.latest_succeeded
      end
    end
  end
end
