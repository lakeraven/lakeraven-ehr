# frozen_string_literal: true

module Lakeraven
  module EHR
    module Gpra
      # Computes the site's National GPRA report with rook over the configured
      # source and keeps it as a GpraRun (#780). Measure logic is rook's
      # (Rook::Crs::NationalGpraReport); this class only feeds it and stores
      # what it returns.
      class ReportRunner
        class NoSourceConfigured < StandardError; end

        def initialize(source: Lakeraven::EHR.configuration.gpra_source, today: Date.current)
          @source = source
          @today = today
        end

        # Records a failed run, rather than none, when the source or rook
        # raises, so the homepage says the latest report could not be computed
        # instead of showing an older one as current. Re-raises for the job's
        # own error reporting.
        def run!
          raise NoSourceConfigured, "config.gpra_source is not set" if @source.nil?

          period = Period.containing(@today)
          run = GpraRun.create!(period_start: period.first, period_end: period.last,
                                status: "running", started_at: Time.current)
          begin
            report = Rook::Crs::NationalGpraReport.new(resources: @source.resources, period: period)
            finish!(run, report.results)
          rescue StandardError => e
            run.update!(status: "failed", finished_at: Time.current, error_class: e.class.name)
            raise
          end
          run
        end

        private

        def finish!(run, results)
          GpraRun.transaction do
            results.each do |result|
              rows = result.care_gaps.map do |gap|
                { gpra_run_id: run.id, measure_id: result.measure.id, patient_dfn: gap.patient.id.to_s, reason: gap.reason }
              end
              GpraCareGap.insert_all!(rows) if rows.any?
            end
            run.update!(status: "succeeded", finished_at: Time.current, measures: results.map { |r| measure_entry(r) })
          end
        end

        def measure_entry(result)
          measure = result.measure
          {
            "id" => measure.id,
            "title" => measure.title,
            "interpretation" => measure.interpretation,
            "improvement_notation" => measure.improvement_notation.to_s,
            "denominator" => result.denominator,
            "numerator" => result.numerator,
            "rate" => result.denominator.positive? ? result.rate : nil,
            "care_gap_count" => result.care_gaps.size,
            "measure_report" => result.measure_report.to_hash
          }
        end
      end
    end
  end
end
