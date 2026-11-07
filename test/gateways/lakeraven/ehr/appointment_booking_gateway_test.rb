# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-01.5: two schedulers booking the last place in a block at once
# (#725). RPMS files both (BSDX ADD NEW APPOINTMENT locks only the patient), so
# the gateway's lock is what keeps the second out. RPMS is stood in for by a
# clinic day that answers what has been filed so far, slowly, as a live broker
# round trip does.
module Lakeraven
  module EHR
    class AppointmentBookingGatewayTest < ActiveSupport::TestCase
      DAY = Date.new(2026, 10, 28)
      RESOURCE = { id: 2, name: "DEMO IHS CLINIC", time_scale: 15, hospital_location_id: 3 }.freeze

      def at(hour, min = 0) = Time.new(DAY.year, DAY.month, DAY.day, hour, min)

      # One block of 1 slot, 09:00-10:00; bookings are filed after a pause.
      class OnePlaceClinic
        attr_reader :filed

        def initialize(at)
          @block = { start_time: at.call(9), end_time: at.call(10), slots: 1 }
          @filed = Queue.new
          @listed = []
        end

        def slot_schedule(**) = [ @block ]
        def appointments(**) = @listed.dup

        def add_appointment(start_time:, end_time:, **)
          sleep 0.05
          @listed << { start_time: start_time, end_time: end_time, cancelled: false }
          @filed << start_time
          { success: true, appointment_id: @listed.size }
        end
      end

      module NoRules
        def self.clinic_rules(_) = nil
        def self.holidays(**) = []
        def self.access_types = []
      end

      test "S-SCH-01.5 of two simultaneous bookings for the last place, only one is filed" do
        clinic = OnePlaceClinic.new(method(:at))
        booking = AppointmentBooking.new(patient_dfn: "3", start: "2026-10-28T09:00", length: "15", note: "")

        results = 2.times.map do
          Thread.new { AppointmentBookingGateway.book_if_room(booking, RESOURCE, via: clinic, setup: NoRules) }
        end.map(&:value)

        assert_equal 1, clinic.filed.size
        assert_equal %i[booked full], results.map(&:status).sort
      end
    end
  end
end
