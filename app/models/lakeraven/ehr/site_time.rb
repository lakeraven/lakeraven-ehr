# frozen_string_literal: true

require "rpms_rpc/api/orwu"

module Lakeraven
  module EHR
    # The site's clock (#1065, #1114): "now" and "today" as RPMS counts them,
    # read from the RPMS server through ORWU DT "NOW" (RpmsRpc::Orwu, FileMan's
    # %DT). RPMS keeps the site's time, and checks a date or time against its
    # own clock ("cannot be in the future"), so a form's default, the clinic's
    # "today" and the engine's own checks all use that clock. The app server's
    # clock is not the site's: it runs in UTC, which is already tomorrow during
    # a US site's evening.
    #
    # now is a wall-clock Time built as rpms-rpc builds every FileMan time
    # (Time.new, the process's zone; see WallClock), so it compares directly
    # with appointment and check-in times read from RPMS.
    #
    # local shows an instant the app stored itself (a screening's time, kept
    # in UTC) on the site's clock, at the offset between RPMS's clock and UTC
    # now, to the nearest quarter hour.
    #
    # Read once per request. When RPMS does not answer, the app's own clock is
    # used and the failure is logged; RPMS still checks whatever is filed.
    class SiteTime < ActiveSupport::CurrentAttributes
      QUARTER_HOUR = 15 * 60

      attribute :now_on_file, :utc_offset_on_file

      class << self
        def now
          read_clock unless now_on_file
          now_on_file
        end

        def today = now.to_date

        # An instant (a Time in any zone) as the site's wall clock.
        def local(instant)
          instant&.getlocal(utc_offset)
        end

        # The site's offset from UTC in seconds, as RPMS's clock shows it.
        def utc_offset
          read_clock unless utc_offset_on_file
          utc_offset_on_file
        end

        # How the clock is read: returns the site's wall-clock Time. The test
        # suite, whose stand-in for RPMS has no server clock, sets its own
        # (test/test_helper.rb).
        attr_writer :reader

        def reader = @reader || method(:read_from_rpms)

        private

        def read_clock
          utc = Time.now.utc
          wall = read || Time.now
          self.now_on_file = wall
          self.utc_offset_on_file = offset_between(wall, utc)
        end

        def read
          time = reader.call
          return time if time.is_a?(Time)

          Rails.logger.error("[site_time] RPMS did not give its time (#{time.inspect}); using the app server's")
          nil
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          Rails.logger.error("[site_time] RPMS time read failed: #{e.class}; using the app server's")
          nil
        end

        # The wall clock's fields read as UTC, less the UTC instant, rounded to
        # the quarter hour so a clock a few minutes adrift still gives the zone.
        def offset_between(wall, utc)
          as_utc = Time.utc(wall.year, wall.month, wall.day, wall.hour, wall.min, wall.sec)
          ((as_utc - utc) / QUARTER_HOUR).round * QUARTER_HOUR
        end

        def read_from_rpms
          ::RpmsRpc::FilemanDateParser.parse_datetime(::RpmsRpc::Orwu.fileman_datetime("NOW"))
        end
      end
    end
  end
end
