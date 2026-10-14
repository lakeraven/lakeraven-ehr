# frozen_string_literal: true

module Lakeraven
  module EHR
    # Named presets over treatment plans, each with its count, for the
    # clinical worklist. This is the query side only; the shared preset UI,
    # URL sync and per-user memory belong to #470.
    class TreatmentPlanWorklist
      Preset = Struct.new(:key, :label, :plans, keyword_init: true) do
        def count = plans.count
      end

      PRESETS = {
        "reviews-overdue" => {
          label: "Reviews overdue",
          query: ->(as_of) { TreatmentPlan.reviews_overdue(as_of: as_of) }
        }
      }.freeze

      def initialize(as_of: Date.current)
        @as_of = as_of
      end

      def presets = PRESETS.keys.map { |key| preset(key) }

      # An unknown key raises: a misspelled preset must not read as an empty
      # worklist with nothing waiting.
      def preset(key)
        definition = PRESETS.fetch(key)
        Preset.new(key: key, label: definition[:label], plans: definition[:query].call(@as_of))
      end
    end
  end
end
