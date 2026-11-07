# frozen_string_literal: true

require "rpms_rpc/api/scheduling"

module Lakeraven
  module EHR
    # Setting a clinic's hours (rpms-ux S-SCH-14) through RpmsRpc::Scheduling:
    # each chosen day's blocks in BSDX ACCESS BLOCK (#9002018.3) are removed
    # (BSDX CANCEL AV BY DATE) and the new block filed (BSDX ADD NEW
    # AVAILABILITY), so a day set again is replaced, not doubled (S-SCH-14.4).
    #
    # BSDX CANCEL AV BY DATE deletes a day's blocks whatever is booked in them,
    # so the bookings are checked here first (S-SCH-14.5): if an active
    # appointment on a chosen day falls outside the new hours, nothing is
    # changed. Each day is then replaced under that resource and day's booking
    # lock, after reading its appointments again, so a booking made meanwhile
    # stops the run at that day instead of being left outside the hours.
    class ClinicHoursGateway
      # status: :set, :conflict (conflicts names the appointments), :stopped (an
      # RPMS refusal or a late booking on stopped_on; days_set were set before
      # it), or :unknown (RPMS did not answer).
      Result = Data.define(:status, :days_set, :conflicts, :stopped_on, :message) do
        def set? = status == :set
      end

      def self.set(hours, resource, via: ::RpmsRpc::Scheduling)
        days = hours.days
        conflicts = outside(hours, booked(resource, days.first, days.last, via: via))
        return result(:conflict, conflicts: conflicts) if conflicts.any?

        days.each_with_object([]) do |date, done|
          stop = AppointmentBookingGateway.lock_for(resource, date).synchronize { replace_day(hours, resource, date, via: via) }
          return result(stop[:status], days_set: done, stopped_on: date, conflicts: stop[:conflicts], message: stop[:message]) if stop

          done << date
        end.then { |done| result(:set, days_set: done) }
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] setting hours raised #{e.class}; the outcome is unknown")
        result(:unknown)
      end

      # One day: nil when replaced, or why it stopped.
      def self.replace_day(hours, resource, date, via:)
        late = outside(hours, booked(resource, date, date, via: via))
        return { status: :conflict, conflicts: late } if late.any?

        removed = via.cancel_availability_by_date(resource_id: resource[:id], start_date: date, end_date: date)
        return refusal(removed) unless removed&.dig(:success)

        added = via.add_availability(resource: resource[:name], start_time: hours.opens_on(date), end_time: hours.closes_on(date),
                                     slots: hours.slots, access_type_id: hours.access_type_id)
        refusal(added) unless added&.dig(:success)
      end
      private_class_method :replace_day

      # Active appointments: not cancelled and not a no-show.
      def self.booked(resource, from, to, via:)
        return [] if from.nil?

        Array(via.appointments(resource: resource[:name], start_date: from, end_date: to)).reject { |a| a[:cancelled] || a[:no_show] }
      end
      private_class_method :booked

      # The appointments on a chosen day that the new hours would not cover.
      def self.outside(hours, appointments)
        appointments.select do |a|
          date = a[:start_time].to_date
          hours.weekdays.include?(date.cwday) && (hours.first..hours.last).cover?(date) &&
            !(a[:start_time] >= hours.opens_on(date) && (a[:end_time] || a[:start_time]) <= hours.closes_on(date))
        end
      end
      private_class_method :outside

      def self.refusal(reply)
        reply.nil? ? { status: :unknown } : { status: :stopped, message: reply[:error].to_s }
      end
      private_class_method :refusal

      def self.result(status, days_set: [], conflicts: [], stopped_on: nil, message: nil)
        Result.new(status: status, days_set: days_set, conflicts: Array(conflicts), stopped_on: stopped_on, message: message)
      end
      private_class_method :result
    end
  end
end
