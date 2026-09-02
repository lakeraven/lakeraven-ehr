# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR date search-parameter semantics for in-memory result sets
    # (Vardana §4: `date=ge{date}` floors and `_sort=-date` ordering).
    # Supports the ge/gt/le/lt prefixes plus a bare date (same-day match);
    # an unparseable expression filters nothing rather than erroring, per
    # the lenient-search convention the other params follow.
    module FHIRDateSearch
      extend ActiveSupport::Concern

      DATE_PREFIXES = {
        "ge" => :>=,
        "gt" => :>,
        "le" => :<=,
        "lt" => :<
      }.freeze

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
        prefix = expression[0, 2]
        if DATE_PREFIXES.key?(prefix)
          boundary = parse_time(expression[2..])
          return items if boundary.nil?

          items.select do |item|
            timestamp = extract.call(item)
            timestamp && timestamp.public_send(DATE_PREFIXES[prefix], boundary)
          end
        else
          date = parse_date(expression)
          return items if date.nil?

          items.select do |item|
            timestamp = extract.call(item)
            timestamp && timestamp.to_date == date
          end
        end
      end

      def parse_time(value)
        Time.zone ? Time.zone.parse(value) : Time.parse(value)
      rescue ArgumentError, TypeError
        nil
      end

      def parse_date(value)
        Date.parse(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
