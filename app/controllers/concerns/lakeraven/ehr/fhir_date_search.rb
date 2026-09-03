# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR date search-parameter semantics for in-memory result sets
    # (Vardana §4: `date=ge{date}` floors and `_sort=-date` ordering).
    # Supports the ge/gt/le/lt prefixes plus a bare date (equality), with
    # FHIR R4 date-precision semantics: a partial date names the WHOLE
    # period at its precision (a bare "2025-01-10" is the whole day, a
    # "2025-01" the whole month), so
    #   ge → on/after the period start     gt → after the period end
    #   le → on/before the period end      lt → before the period start
    #   (none) → within the period
    # An unparseable expression filters nothing rather than erroring, per
    # the lenient-search convention the other params follow.
    module FHIRDateSearch
      extend ActiveSupport::Concern

      private

      # Filters `items` by a raw date param value (String or Array of
      # Strings); `extract` yields each item's timestamp. Items without a
      # timestamp never match a date filter.
      def apply_date_param(items, raw, &extract)
        Array(raw).reject(&:blank?).reduce(items) do |scope, expression|
          filter_by_date_expression(scope, expression.to_s, &extract)
        end
      end

      # Sorts by the extracted timestamp when `sort_param` is "date" or
      # "-date"; any other value leaves the order untouched.
      def apply_date_sort(items, sort_param, &extract)
        return items unless %w[date -date].include?(sort_param.to_s)

        sorted = items.sort_by { |item| extract.call(item) || Time.at(0) }
        sort_param.to_s.start_with?("-") ? sorted.reverse : sorted
      end

      def filter_by_date_expression(items, expression, &extract)
        prefix = %w[ge gt le lt].find { |p| expression.start_with?(p) }
        period = parse_period(prefix ? expression[2..] : expression)
        return items if period.nil?

        lower, upper = period
        items.select do |item|
          timestamp = extract.call(item)
          next false unless timestamp

          case prefix
          when "ge" then timestamp >= lower
          when "gt" then timestamp >= upper
          when "le" then timestamp < upper
          when "lt" then timestamp < lower
          else timestamp >= lower && timestamp < upper
          end
        end
      end

      # The [start, end) period a FHIR date expression names, at its own
      # precision: instants collapse to a point, partial dates cover the
      # whole year/month/day. nil when unparseable.
      def parse_period(value)
        case value.to_s.strip
        when /\A(\d{4})\z/
          year = Regexp.last_match(1).to_i
          [ time_at(year, 1, 1), time_at(year + 1, 1, 1) ]
        when /\A(\d{4})-(\d{2})\z/
          year = Regexp.last_match(1).to_i
          month = Regexp.last_match(2).to_i
          return nil unless (1..12).cover?(month)
          start = time_at(year, month, 1)
          [ start, start + 1.month ]
        when /\A(\d{4})-(\d{2})-(\d{2})\z/
          date = Date.parse(Regexp.last_match(0))
          start = time_at(date.year, date.month, date.day)
          [ start, start + 1.day ]
        else
          # Full date-time — treat as second precision (a one-second period).
          instant = parse_time(value)
          instant && [ instant, instant + 1.second ]
        end
      rescue ArgumentError, TypeError
        nil
      end

      def time_at(year, month, day)
        Time.zone ? Time.zone.local(year, month, day) : Time.local(year, month, day)
      end

      def parse_time(value)
        Time.zone ? Time.zone.parse(value) : Time.parse(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
