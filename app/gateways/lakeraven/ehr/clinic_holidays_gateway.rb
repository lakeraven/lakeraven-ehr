# frozen_string_literal: true

require "rpms_rpc/api/scheduling_setup"

module Lakeraven
  module EHR
    # #616: HOLIDAY (#40.5) is site-wide, not a clinic-owned table. This read
    # pairs its dates with #44's SCHEDULE ON HOLIDAYS? without changing either.
    class ClinicHolidaysGateway
      Result = Data.define(:holidays, :schedule_on_holidays)

      def self.read(resource, year:, via: ::RpmsRpc::SchedulingSetup)
        first = Date.new(year, 1, 1)
        last = Date.new(year, 12, 31)
        rules = via.clinic_rules(resource[:hospital_location_id])
        return unless rules.is_a?(Hash) && [ true, false ].include?(rules[:schedule_on_holidays])

        rows = via.holidays(start_date: first, end_date: last)
        return unless rows.is_a?(Array) && rows.all? { |row| valid_row?(row, first..last) }

        Result.new(holidays: rows.sort_by { |row| row[:date] }, schedule_on_holidays: rules[:schedule_on_holidays])
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] reading clinic holidays raised #{e.class}")
        nil
      end

      def self.valid_row?(row, range)
        row.is_a?(Hash) && row[:date].instance_of?(Date) && range.cover?(row[:date]) && row[:name].is_a?(String)
      end
      private_class_method :valid_row?
    end
  end
end
