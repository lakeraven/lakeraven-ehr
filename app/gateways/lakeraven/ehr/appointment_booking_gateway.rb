# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/scheduling"

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

      def self.resources(via: ::RpmsRpc::Scheduling)
        Array(via.resources)
      end

      def self.resource(id, via: ::RpmsRpc::Scheduling)
        resources(via: via).find { |r| r[:id] == id.to_i }
      end

      # The resource's day: its blocks, and its appointments with their ids and
      # state (BSDX CREATE APPT SCHEDULE). A cancelled appointment frees its
      # place, so only the others count against the slots.
      def self.day(resource, date, via: ::RpmsRpc::Scheduling)
        blocks = Array(via.slot_schedule(resource: resource[:name], start_date: date, end_date: date))
        listed = Array(via.appointments(resource: resource[:name], start_date: date, end_date: date))
        [ ClinicDay.new(blocks: blocks, appointments: listed.reject { |a| a[:cancelled] }, time_scale: resource[:time_scale]), listed ]
      end

      def self.appointment(resource, id, date, via: ::RpmsRpc::Scheduling)
        Array(via.appointments(resource: resource[:name], start_date: date, end_date: date)).find { |a| a[:id] == id.to_i }
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

      def self.book(booking, resource, via: ::RpmsRpc::Scheduling)
        reply = via.add_appointment(patient_dfn: booking.patient_dfn, resource: resource[:name],
                                    start_time: booking.start_time, end_time: booking.end_time,
                                    length_minutes: booking.length, note: booking.note)
        return Result.new(status: :unknown, appointment_id: nil, message: nil) if reply.nil?
        return Result.new(status: :booked, appointment_id: reply[:appointment_id], message: nil) if reply[:success]

        Result.new(status: :refused, appointment_id: nil, message: reply[:error].to_s)
      rescue ::RpmsRpc::Client::RpcError, ::RpmsRpc::Client::ConnectionError, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] booking raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, appointment_id: nil, message: nil)
      end
    end
  end
end
