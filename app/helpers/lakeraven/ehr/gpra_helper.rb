# frozen_string_literal: true

module Lakeraven
  module EHR
    # Reading a GPRA run's measure entry for the homepage tiles (#780).
    module GpraHelper
      def gpra_percent(rate)
        rate.nil? ? "No patients" : number_to_percentage(rate * 100, precision: 1)
      end

      def gpra_lower_is_better?(measure)
        measure["improvement_notation"] == "decrease"
      end

      # Whether the rate meets the target, read the way the measure improves.
      def gpra_meets_target?(measure, target)
        return nil if target.nil? || measure["rate"].nil?

        gpra_lower_is_better?(measure) ? measure["rate"] <= target : measure["rate"] >= target
      end

      # The change in percentage points since the previous run, and whether
      # that is better or worse for this measure. nil when either rate is
      # missing.
      def gpra_change(measure, previous)
        before = previous&.measure(measure["id"])&.dig("rate")
        return nil if before.nil? || measure["rate"].nil?

        points = ((measure["rate"] - before) * 100).round(1)
        direction =
          if points.zero? then :same
          elsif (points.positive? && !gpra_lower_is_better?(measure)) || (points.negative? && gpra_lower_is_better?(measure)) then :better
          else :worse
          end
        { points: points, direction: direction }
      end
    end
  end
end
