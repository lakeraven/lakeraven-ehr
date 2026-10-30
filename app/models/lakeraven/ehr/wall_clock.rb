# frozen_string_literal: true

module Lakeraven
  module EHR
    # A time a user enters ("2026-11-06T11:00") as the clinic's wall clock. BSDX
    # times carry no zone, and rpms-rpc reads them as the server's local time
    # (Time.new), so an entered time is built the same way: a UTC time here put
    # every booking hours away from the clinic's blocks on a host not in UTC.
    module WallClock
      FORMAT = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})\z/

      def self.parse(text)
        m = text.to_s.match(FORMAT)
        m && Time.new(*m.captures.map(&:to_i))
      rescue ArgumentError
        nil
      end
    end
  end
end
