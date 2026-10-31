# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"

module Lakeraven
  module EHR
    # Booking an appointment (rpms-ux S-SCH-01) through RpmsRpc::Scheduling: the
    # resources the user may use and their rights (BSDX RESOURCES), a day's
    # blocks and appointments (BSDX CREATE ASGND SLOT SCHED, BSDX ALL
    # APPOINTMENTS), and the booking itself (BSDX ADD NEW APPOINTMENT).
    #
    # The scheduler finds the patient with VueCentric's own patient selection,
    # ORWPT LIST ALL plus the brief header, which run in the scheduler's sign-on
    # context; AG's lookup is the front desk's and is refused to a scheduler.
    class AppointmentBookingGateway
      Result = Data.define(:status, :appointment_id, :message) do
        def booked? = status == :booked
      end

      PATIENT_LIMIT = 15

      # BSDX ADD NEW APPOINTMENT locks only the patient (BSDX07.m:40) and
      # never refuses a full slot, and BSDX has no lock RPC, so the check for
      # room and the booking run under a lock per resource and day here (#725).
      # It covers every lakeraven-ehr user (one web process, ADR 0011), not a
      # VueCentric user booking at the same moment, as stock RPMS does not.
      BOOKING_LOCKS = Array.new(64) { Mutex.new }.freeze

      def self.resources(via: ::RpmsRpc::Scheduling)
        Array(via.resources)
      end

      def self.resource(id, via: ::RpmsRpc::Scheduling)
        resources(via: via).find { |r| r[:id] == id.to_i }
      end

      # The resource's day: its blocks, and its appointments with their ids and
      # state (BSDX CREATE APPT SCHEDULE). A cancelled appointment frees its
      # place, so only the others count against the slots.
      def self.day(resource, date, via: ::RpmsRpc::Scheduling, setup: ::RpmsRpc::SchedulingSetup)
        blocks = Array(via.slot_schedule(resource: resource[:name], start_date: date, end_date: date))
        listed = Array(via.appointments(resource: resource[:name], start_date: date, end_date: date))
        rules = rules_for(resource, date, date, setup: setup)
        [ ClinicDay.new(blocks: blocks, appointments: listed.reject { |a| a[:cancelled] }, time_scale: resource[:time_scale], **rules.call(date)), listed ]
      end

      # The resource's days from from to to, each a ClinicDay, from one read of
      # the blocks and one of the appointments for the whole range (S-SCH-04).
      # BSDX SEARCH AVAILABILITY is not used: SEARCH^BSDX24 returns only a
      # resource's first block and leaves its morning, weekday and type filters
      # unfinished; the open times come from the blocks, as the day view's do.
      def self.days(resource, from, to, via: ::RpmsRpc::Scheduling, setup: ::RpmsRpc::SchedulingSetup)
        blocks = Array(via.slot_schedule(resource: resource[:name], start_date: from, end_date: to)).group_by { |b| b[:start_time].to_date }
        booked = Array(via.appointments(resource: resource[:name], start_date: from, end_date: to)).reject { |a| a[:cancelled] }.group_by { |a| a[:start_time].to_date }
        rules = rules_for(resource, from, to, setup: setup)
        (from..to).to_h do |date|
          [ date, ClinicDay.new(blocks: blocks.fetch(date, []), appointments: booked.fetch(date, []), time_scale: resource[:time_scale], **rules.call(date)) ]
        end
      end

      # Whether a clinic keeps this user out (#729, S-SCH-01.13): its HOSPITAL
      # LOCATION prohibits access (#44 field 2500) and the user is not one of its
      # privileged users, or its principal clinic's, as RPMS's own scheduling
      # checks (SDM1.m:33). SDZSUP is checked by the caller.
      def self.kept_out?(resource, duz, setup: ::RpmsRpc::SchedulingSetup)
        rules = setup.clinic_rules(resource[:hospital_location_id])
        return false unless rules&.dig(:prohibit_access)

        !Array(rules[:privileged_users]).include?(duz.to_i)
      end

      # The access types the search can be kept to (S-SCH-04.6): those neither
      # inactive nor preventing access, by name.
      def self.access_types(setup: ::RpmsRpc::SchedulingSetup)
        Array(setup.access_types).reject { |t| t[:inactive] || t[:prevent_access] }
      end

      # What RPMS says about the resource's clinic over from..to, read once for
      # the range (SchedulingSetup: the clinic's #44 rules, the holidays, the
      # access types that prevent access), as a function from a date to
      # ClinicDay's closed:, prevented: and opens_hour:. A resource with no
      # clinic has no rules. Today is the server's local date, as BSDX times are.
      def self.rules_for(resource, from, to, setup:)
        rules = setup.clinic_rules(resource[:hospital_location_id])
        holidays = Array(setup.holidays(start_date: from, end_date: to)).map { |h| h[:date] }
        prevented = Array(setup.access_types).select { |t| t[:prevent_access] }.map { |t| t[:id] }
        today = Time.now.to_date
        ->(date) { { closed: ClinicDay.closed_on(date, rules: rules, holidays: holidays, today: today), prevented: prevented, opens_hour: rules&.dig(:display_begins) } }
      end
      private_class_method :rules_for

      def self.appointment(resource, id, date, via: ::RpmsRpc::Scheduling)
        Array(via.appointments(resource: resource[:name], start_date: date, end_date: date)).find { |a| a[:id] == id.to_i }
      end

      # One patient's appointments across clinics, earliest first (S-SCH-05.6):
      # BSDX PATIENT APPT DISPLAY, the scheduling client's own list.
      def self.patient_appointments(dfn, via: ::RpmsRpc::Scheduling)
        Array(via.patient_appointments(dfn.to_i)).sort_by { |a| a[:start_time] || Time.at(0) }
      end

      # Patients whose names start with the text, each with HRN and date of birth.
      def self.patients(text, via: ::RpmsRpc::Patient)
        text = text.to_s.strip.upcase
        return [] if text.empty?

        Array(via.search(text)).select { |row| row[:name].to_s.upcase.start_with?(text) }.first(PATIENT_LIMIT).filter_map do |row|
          header = via.brief_header(row[:dfn].to_i)
          header && { dfn: row[:dfn].to_i, name: header[:name] || row[:name], hrn: header[:mrn].presence, dob: header[:dob] }
        end
      end

      # Books if the time still has room, read again under the lock; :full if not.
      def self.book_if_room(booking, resource, via: ::RpmsRpc::Scheduling, setup: ::RpmsRpc::SchedulingSetup)
        date = booking.start_time.to_date
        BOOKING_LOCKS[[ resource[:id], date ].hash % BOOKING_LOCKS.size].synchronize do
          clinic_day, = day(resource, date, via: via, setup: setup)
          next Result.new(status: :full, appointment_id: nil, message: nil) unless clinic_day.room_for?(booking.start_time, booking.length)

          book(booking, resource, via: via)
        end
      end

      def self.book(booking, resource, via: ::RpmsRpc::Scheduling)
        reply = via.add_appointment(patient_dfn: booking.patient_dfn, resource: resource[:name],
                                    start_time: booking.start_time, end_time: booking.end_time,
                                    length_minutes: booking.length, note: booking.note)
        return Result.new(status: :unknown, appointment_id: nil, message: nil) if reply.nil?
        return Result.new(status: :booked, appointment_id: reply[:appointment_id], message: nil) if reply[:success]

        Result.new(status: :refused, appointment_id: nil, message: reply[:error].to_s)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] booking raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, appointment_id: nil, message: nil)
      end
    end
  end
end
