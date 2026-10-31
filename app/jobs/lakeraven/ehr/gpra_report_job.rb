# frozen_string_literal: true

module Lakeraven
  module EHR
    # Computes the GPRA report the homepage shows (#780). The host schedules it,
    # nightly for example; it does nothing until config.gpra_source is set.
    class GpraReportJob < ApplicationJob
      queue_as :low_priority

      def perform
        return if Lakeraven::EHR.configuration.gpra_source.nil?

        Gpra::ReportRunner.new.run!
      end
    end
  end
end
