# frozen_string_literal: true

module Lakeraven
  module EHR
    # Per-program review intervals for behavioral-health treatment plans.
    #
    # The numbers are site configuration, the stand-in for L2/L3 delivery.
    # Seeded programs come from db/data; `assign` replaces one program's
    # intervals without a code change. TreatmentPlanService reads the stored
    # duration and adds it to a date. This class is where an interval lives.
    # The plan model does not have one.
    class BehavioralHealthProgramConfiguration < ApplicationRecord
      self.table_name = "lakeraven_ehr_bh_program_configurations"

      SEED_PATH = Engine.root.join("db/data/behavioral_health_program_review_intervals.yml")
      # Calendar units only, largest first. Hours and smaller make Date +
      # interval a Time, which is not a review due date. duration_from applies
      # parts in this order: Date + duration follows the parts-hash order, and
      # jsonb returns keys sorted, so days can arrive before months.
      PART_UNITS = %i[years months weeks days].freeze

      class UnknownProgram < StandardError; end

      validates :program_key, presence: true, uniqueness: true
      validates :progress_review_interval_parts, presence: true
      validates :end_of_treatment_review_interval_parts, presence: true

      def self.reset! = delete_all

      def self.seed_defaults!
        YAML.safe_load_file(SEED_PATH).each do |program_key, intervals|
          assign(program_key: program_key, **durations_from_seed(intervals))
        end
      end

      def self.assign(program_key:, progress_review_interval:, end_of_treatment_review_interval:)
        record = find_or_initialize_by(program_key: program_key.to_s)
        record.progress_review_interval_parts = parts_for(progress_review_interval)
        record.end_of_treatment_review_interval_parts = parts_for(end_of_treatment_review_interval)
        record.save!
        record
      end

      def self.for_program(program_key)
        find_by(program_key: program_key.to_s) ||
          raise(UnknownProgram, "no review intervals configured for #{program_key.inspect}")
      end

      def progress_review_interval
        self.class.duration_from(progress_review_interval_parts)
      end

      def end_of_treatment_review_interval
        self.class.duration_from(end_of_treatment_review_interval_parts)
      end

      def self.duration_from(parts)
        # A stored interval is a hash. to_h would accept an array of pairs and
        # raise NoMethodError or TypeError for a string, integer, or bare array.
        raise ArgumentError, "duration parts must be a hash: #{parts.inspect}" unless parts.is_a?(Hash)

        normalized = parts.to_h.symbolize_keys
        unknown = normalized.keys - PART_UNITS
        raise ArgumentError, "unsupported duration parts: #{unknown.inspect}" if unknown.any?
        raise ArgumentError, "duration has no parts" if normalized.empty?

        pieces = PART_UNITS.filter_map do |unit|
          duration_piece(unit, normalized.fetch(unit)) if normalized.key?(unit)
        end
        pieces.reduce { |duration, piece| duration + piece }
      end

      def self.durations_from_seed(intervals)
        {
          progress_review_interval: duration_from(intervals.fetch("progress_review_interval")),
          end_of_treatment_review_interval: duration_from(intervals.fetch("end_of_treatment_review_interval"))
        }
      end
      private_class_method :durations_from_seed

      # Integer counts, string keys. Duration parts can carry a Scalar, and
      # jsonb will not round-trip that as a number unless it is coerced here.
      # Zero, negative, and non-numeric counts are not a review cadence.
      def self.parts_for(duration)
        parts = duration.parts
        raise ArgumentError, "duration has no calendar parts: #{duration.inspect}" if parts.blank?

        parts.to_h { |unit, count| [ part_key(unit), positive_integer_count(count) ] }
      end
      private_class_method :parts_for

      def self.part_key(unit)
        key = unit.to_sym
        return key.to_s if PART_UNITS.include?(key)

        raise ArgumentError, "unsupported duration part: #{unit.inspect}"
      end
      private_class_method :part_key

      def self.positive_integer_count(count)
        return count.to_i if integer_count?(count)

        raise ArgumentError, "duration count must be a positive integer: #{count.inspect}"
      end
      private_class_method :positive_integer_count

      def self.integer_count?(count)
        count.is_a?(Numeric) && count == count.to_i && count.positive?
      end
      private_class_method :integer_count?

      def self.duration_piece(unit, count)
        amount = positive_integer_count(count)
        case unit
        when :years then amount.years
        when :months then amount.months
        when :weeks then amount.weeks
        when :days then amount.days
        else raise ArgumentError, "unsupported duration part: #{unit.inspect}"
        end
      end
      private_class_method :duration_piece
    end
  end
end
