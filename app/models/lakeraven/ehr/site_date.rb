# frozen_string_literal: true

require "rpms_rpc/api/orwu"

module Lakeraven
  module EHR
    # "Today" as RPMS counts it (#1065): the RPMS server's date, FileMan's DT,
    # read through ORWU DT "T" (RpmsRpc::Orwu). RPMS checks a date against its
    # own today ("cannot be in the future"), so a form's default and the
    # engine's own check use the same day. The app server's clock is not that
    # day: it runs in UTC, which is already tomorrow during a US site's
    # evening.
    #
    # Read once per request. When RPMS does not answer, the app's own date is
    # used and the failure is logged; RPMS still checks whatever is filed.
    class SiteDate < ActiveSupport::CurrentAttributes
      attribute :today_on_file

      class << self
        def today
          self.today_on_file ||= read
        end

        # How the date is read. The mocked test suite, whose broker has no
        # server clock, sets its own (test/test_helper.rb).
        attr_writer :reader

        def reader = @reader || method(:read_from_rpms)

        private

        def read
          date = reader.call
          return date if date.is_a?(Date)

          Rails.logger.error("[site_date] RPMS did not give its date (#{date.inspect}); using the app server's")
          Date.current
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          Rails.logger.error("[site_date] RPMS date read failed: #{e.class}; using the app server's")
          Date.current
        end

        def read_from_rpms
          ::RpmsRpc::FilemanDateParser.parse_date(::RpmsRpc::Orwu.fileman_datetime("T"))
        end
      end
    end
  end
end
