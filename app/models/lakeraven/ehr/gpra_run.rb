# frozen_string_literal: true

module Lakeraven
  module EHR
    # One computation of the site's GPRA report (#780). See the migration for
    # what a run keeps and why.
    class GpraRun < ApplicationRecord
      self.table_name = "lakeraven_ehr_gpra_runs"

      STATUSES = %w[running succeeded failed].freeze

      has_many :care_gaps, class_name: "Lakeraven::EHR::GpraCareGap", inverse_of: :gpra_run

      validates :status, inclusion: { in: STATUSES }

      scope :succeeded, -> { where(status: "succeeded") }

      # The run the homepage shows: the newest that finished successfully.
      def self.latest_succeeded
        succeeded.order(finished_at: :desc, id: :desc).first
      end

      # The newest run of any status, so a failure after a good run is shown.
      def self.latest
        order(started_at: :desc, id: :desc).first
      end

      def succeeded? = status == "succeeded"
      def failed? = status == "failed"
      def running? = status == "running"

      def measure(measure_id)
        measures.find { |m| m["id"] == measure_id.to_s }
      end

      # The successful run before this one, for each tile's change since then.
      def previous_succeeded
        GpraRun.succeeded.where(finished_at: ...finished_at).order(finished_at: :desc, id: :desc).first
      end
    end
  end
end
