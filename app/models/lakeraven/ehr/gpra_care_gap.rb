# frozen_string_literal: true

module Lakeraven
  module EHR
    # A patient in a measure's denominator who still needs care, as of one GPRA
    # run (#780). Holds the DFN and rook's reason only.
    class GpraCareGap < ApplicationRecord
      self.table_name = "lakeraven_ehr_gpra_care_gaps"

      belongs_to :gpra_run, class_name: "Lakeraven::EHR::GpraRun", inverse_of: :care_gaps
    end
  end
end
