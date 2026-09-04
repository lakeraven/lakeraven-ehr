# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR `date` search parameter + `_sort=date/-date` support, shared by the
    # controllers whose resources search on a clinical date (Observation on
    # effectiveDateTime, Encounter on period.start, DiagnosticReport on
    # effectiveDateTime — Vardana profile section 4: `date=ge{date}`).
    #
    # Comparison prefixes apply to the item's date; repeated date params AND
    # together. Items without a date sort last either way.
    module FHIRDateSearch
      # FHIR date search comparison prefixes (default is exact match).
      DATE_PREFIXES = %w[ge le gt lt eq].freeze

      private

      def filter_by_fhir_date(items, &date_of)
        Array(params[:date]).each do |expression|
          prefix = DATE_PREFIXES.find { |p| expression.start_with?(p) } || "eq"
          boundary = parse_search_date(expression.delete_prefix(prefix))
          next unless boundary

          items = items.select do |item|
            date = date_of.call(item)&.to_date
            date && fhir_date_matches?(date, prefix, boundary)
          end
        end
        items
      end

      def parse_search_date(value)
        Date.parse(value)
      rescue ArgumentError, TypeError
        nil
      end

      def fhir_date_matches?(date, prefix, boundary)
        case prefix
        when "ge" then date >= boundary
        when "le" then date <= boundary
        when "gt" then date > boundary
        when "lt" then date < boundary
        else date == boundary
        end
      end

      def sort_by_fhir_date(items, &date_of)
        return items unless %w[date -date].include?(params[:_sort])

        sorted, undated = items.partition { |item| date_of.call(item).present? }
        sorted = sorted.sort_by(&date_of)
        sorted = sorted.reverse if params[:_sort] == "-date"
        sorted + undated
      end
    end
  end
end
