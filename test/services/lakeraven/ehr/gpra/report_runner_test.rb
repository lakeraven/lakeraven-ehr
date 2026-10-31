# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module Gpra
      # The runner stores what rook computes over the configured source, and a
      # failure as a failed run (#780).
      class ReportRunnerTest < ActiveSupport::TestCase
        TODAY = Date.new(2026, 3, 1)
        DEPRESSION_ADULT = "crs-v25-depression-screening-18-"

        def population = file_fixture("gpra_population").to_s

        def run_report(source = NdjsonDirectorySource.new(population))
          ReportRunner.new(source: source, today: TODAY).run!
        end

        test "the GPRA year runs from 1 July to 30 June" do
          assert_equal Date.new(2025, 7, 1)..Date.new(2026, 6, 30), Period.containing(TODAY)
          assert_equal Date.new(2026, 7, 1)..Date.new(2027, 6, 30), Period.containing(Date.new(2026, 7, 1))
          assert_equal Date.new(2025, 7, 1)..Date.new(2026, 6, 30), Period.containing(Date.new(2026, 6, 30))
        end

        test "a run stores the counts rook computes for the same population" do
          run = run_report

          assert run.succeeded?
          assert_equal [ Date.new(2025, 7, 1), Date.new(2026, 6, 30) ], [ run.period_start, run.period_end ]
          resources = NdjsonDirectorySource.new(population).resources
          rook = Rook::Crs::NationalGpraReport.new(resources: resources, period: Period.containing(TODAY)).results
          assert_equal rook.map { |r| [ r.measure.id, r.denominator, r.numerator ] },
                       run.measures.map { |m| [ m["id"], m["denominator"], m["numerator"] ] }
        end

        test "adult depression screening: two AI/AN adults, one screened" do
          measure = run_report.measure(DEPRESSION_ADULT)

          assert_equal [ 2, 1, 0.5 ], measure.values_at("denominator", "numerator", "rate")
          assert_equal "increase", measure["improvement_notation"]
          assert_equal "MeasureReport", measure.dig("measure_report", "resourceType")
        end

        test "care gaps keep the DFN and rook's reason, and nothing else" do
          run = run_report
          gaps = run.care_gaps.where(measure_id: DEPRESSION_ADULT)

          assert_equal [ "101" ], gaps.map(&:patient_dfn)
          assert_match(/No depression screening/, gaps.first.reason)
          assert_equal %w[gpra_run_id id measure_id patient_dfn reason], GpraCareGap.column_names.sort
        end

        test "a measure with no patients has no rate rather than zero" do
          measure = run_report.measure("crs-v25-controlling-high-blood-pressure")

          assert_equal 0, measure["denominator"]
          assert_nil measure["rate"]
        end

        test "a source that raises leaves a failed run naming only the error class" do
          broken = Object.new
          def broken.resources = raise(ArgumentError, "no .ndjson files found in /secret/path")

          assert_raises(ArgumentError) { run_report(broken) }
          run = GpraRun.latest
          assert run.failed?
          assert_equal "ArgumentError", run.error_class
          assert_empty run.measures
          assert_nil GpraRun.latest_succeeded
        end

        test "an empty directory fails the run instead of reporting no patients" do
          Dir.mktmpdir do |dir|
            assert_raises(ArgumentError) { run_report(NdjsonDirectorySource.new(dir)) }
          end
          assert GpraRun.latest.failed?
        end

        test "no source configured is refused before any run is recorded" do
          assert_raises(ReportRunner::NoSourceConfigured) { ReportRunner.new(source: nil).run! }
          assert_equal 0, GpraRun.count
        end
      end
    end
  end
end
