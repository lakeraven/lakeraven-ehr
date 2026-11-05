# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # FHIR R4 date search (#846): one value of a `date` parameter, with its
      # prefix, compared against the date a resource serves.
      #
      # A date is a range as wide as its precision: 2024-03 is all of March.
      # A served Period is the range from start to end, open where it has no
      # end. Comparisons follow the table in R4's "date" search section: eq
      # means the value's range holds the resource's, and gt, lt, ge, le, sa
      # and eb compare the two ranges. A date with no time zone is read in the
      # server's zone. `ap` has no defined width, so it is not offered.
      class DateSearch
        PATTERN = /\A(\d{4})(?:-(\d{2})(?:-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:\d{2})?)?)?)?\z/
        PREFIXES = %w[eq ne gt lt ge le sa eb].freeze
        FORMS = "a date such as 2024, 2024-03, 2024-03-15 or 2024-03-15T10:00:00Z, " \
                "after an optional prefix: #{PREFIXES.join(', ')}".freeze

        # The half-open range [first, last) a date value covers, or nil.
        def self.range_of(text)
          match = PATTERN.match(text.to_s)
          return nil unless match

          year, month, day, hour, minute, second, zone = match.captures
          return nil unless ::Date.valid_date?(year.to_i, (month || 1).to_i, (day || 1).to_i)

          first = instant(year, month, day, hour, minute, second, zone)
          first...(first + width(month, day, hour, second))
        rescue ArgumentError
          nil
        end

        def self.instant(year, month, day, hour, minute, second, zone)
          parts = [ year.to_i, (month || 1).to_i, (day || 1).to_i, hour.to_i, minute.to_i, second.to_i ]
          return Time.zone.local(*parts) if zone.nil?

          Time.new(*parts, zone == "Z" ? "UTC" : zone)
        end
        private_class_method :instant

        def self.width(month, day, hour, second)
          return 1.year unless month
          return 1.month unless day
          return 1.day unless hour

          second ? 1.second : 1.minute
        end
        private_class_method :width

        # The resource's range for a served value: a dateTime or date String,
        # or a Period Hash. An open end reaches to the edge of time.
        def self.served_range(value)
          return range_of(value) if value.is_a?(String)
          return nil unless value.is_a?(Hash)

          start = range_of(value[:start] || value["start"])
          finish = range_of(value[:end] || value["end"])
          return nil unless start || finish

          (start&.begin || Time.at(-1 << 40))...(finish&.end || Time.at(1 << 40))
        end

        # One value of the parameter, or nil when it is not a date.
        def self.parse(text)
          prefix = text.to_s[/\A[a-z]{2}/]
          prefix = nil unless PREFIXES.include?(prefix)
          range = range_of(prefix ? text[2..] : text)
          new(prefix || "eq", range) if range
        end

        def initialize(prefix, range)
          @prefix = prefix
          @range = range
        end

        def matches?(served)
          case @prefix
          when "eq" then within?(served)
          when "ne" then !within?(served)
          when "gt" then served.end > @range.end
          when "lt" then served.begin < @range.begin
          when "ge" then served.end > @range.end || within?(served)
          when "le" then served.begin < @range.begin || within?(served)
          when "sa" then served.begin >= @range.end
          when "eb" then served.end <= @range.begin
          end
        end

        private

        def within?(served)
          served.begin >= @range.begin && served.end <= @range.end
        end
      end
    end
  end
end
