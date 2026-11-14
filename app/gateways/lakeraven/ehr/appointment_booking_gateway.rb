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

      # The lock a resource's day is booked and its hours replaced under.
      def self.lock_for(resource, date) = BOOKING_LOCKS[[ resource[:id], date ].hash % BOOKING_LOCKS.size]

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

      # The access types by id, for naming a block (S-SCH-05.2).
      def self.access_type_names(setup: ::RpmsRpc::SchedulingSetup)
        Array(setup.access_types).to_h { |t| [ t[:id], t[:name] ] }
      end

      # The day's appointments with what the BSDX reads leave out (S-SCH-05.3):
      # :cancelled_by on a cancelled one, and :overbook on the others.
      def self.marked(resource, appointments, setup: ::RpmsRpc::SchedulingSetup)
        clinic = resource[:hospital_location_id]
        appointments.map do |a|
          where = { start_time: a[:start_time], patient_dfn: a[:patient_dfn] }
          if a[:cancelled]
            a.merge(cancelled_by: setup.cancelled_by(**where))
          else
            a.merge(overbook: clinic.present? && setup.overbook?(hospital_location_id: clinic, **where))
          end
        end
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

      # How many appointments each resource holds on date, by resource name, from
      # one read across every resource: BSDX ALL APPOINTMENTS (APBLKALL^BSDX05).
      # The routine counts walk-ins and leaves out cancelled and no-show
      # appointments (STCOMM^BSDX05). A resource with none is not a key.
      def self.booked_counts(date, via: ::RpmsRpc::Scheduling)
        Array(via.all_appointments(start_date: date, end_date: date)).group_by { |a| a[:resource_name] }.transform_values(&:size)
      end

      # Every appointment on the resources over dates, cancelled ones too, each
      # with its clinic (S-SCH-05.5). One read per resource: BSDX ALL
      # APPOINTMENTS leaves out what is cancelled or a no-show.
      def self.listed(resources, dates, via: ::RpmsRpc::Scheduling)
        resources.flat_map do |resource|
          Array(via.appointments(resource: resource[:name], start_date: dates.begin, end_date: dates.end))
            .map { |a| a.merge(clinic: resource.slice(:id, :name)) }
        end
      end

      # The appointments needing action on the resources over window, earliest
      # first (#875, rpms-ux S-SCH-13.5): past their start time with no check-in,
      # check-out, cancellation or no-show recorded on BSDX APPOINTMENT, the
      # appointments RPMS's own Appointments Requiring Action report lists
      # (BSDAMR2: no status, or NO ACTION TAKEN). BSDX ALL APPOINTMENTS names the
      # resources with a past appointment not cancelled or a no-show, and only
      # those resources' days are read (BSDX CREATE APPT SCHEDULE), each row
      # with its resource as :clinic. now is the server's local time, as BSDX
      # times are.
      def self.needing_action(resources, window, now: Time.now, via: ::RpmsRpc::Scheduling)
        booked = Array(via.all_appointments(start_date: window.begin, end_date: window.end))
        names = booked.select { |a| a[:start_time] < now }.to_set { |a| a[:resource_name] }
        resources.select { |r| names.include?(r[:name]) }.flat_map do |resource|
          Array(via.appointments(resource: resource[:name], start_date: window.begin, end_date: window.end))
            .select { |a| needs_action?(a, now) }.map { |a| a.merge(clinic: resource) }
        end.sort_by { |a| a[:start_time] }
      end

      def self.needs_action?(appointment, now)
        appointment[:start_time] < now && !appointment[:cancelled] && !appointment[:no_show] &&
          appointment[:checkin_time].nil? && appointment[:checkout_time].nil?
      end

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
      # access_type: "WALKIN" books a walk-in (S-SCH-06.1); nil a scheduled appointment.
      #
      # overbook: who is booking, for a time with no room ({ duz:, supervisor:,
      # confirmed: }), or nil to never overbook. When the overbook rules of
      # S-SCH-01.9 to 01.11 let them (overbook_permitted?), the answer is
      # :overbook_offered until they confirm; a confirmed overbook is booked
      # and then marked OVERBOOK (#44.003 field 9), as BPRM marks it (#603).
      def self.book_if_room(booking, resource, via: ::RpmsRpc::Scheduling, setup: ::RpmsRpc::SchedulingSetup, access_type: nil, overbook: nil)
        date = booking.start_time.to_date
        lock_for(resource, date).synchronize do
          clinic_day, = day(resource, date, via: via, setup: setup)
          next book(booking, resource, via: via, access_type: access_type) if clinic_day.room_for?(booking.start_time, booking.length)
          unless overbook && overbook_permitted?(clinic_day, booking, resource, overbook, via: via, setup: setup)
            next Result.new(status: :full, appointment_id: nil, message: why_no_room(clinic_day, booking, resource, setup: setup))
          end
          next Result.new(status: :overbook_offered, appointment_id: nil, message: nil) unless overbook[:confirmed]

          booked = book(booking, resource, via: via, access_type: access_type)
          booked.booked? ? mark_overbook(booked, booking, resource, setup: setup) : booked
        end
      end

      # Why a time took no booking, when RPMS says more than "full": the day is
      # past the clinic's maximum days for future booking (#44 field 2002,
      # S-SCH-15.6), a holiday the clinic does not schedule on, or the clinic is
      # inactive; or the time is in a block whose access type prevents access
      # (BSDX ACCESS TYPE .08, S-SCH-17.2). nil for a time that is simply full
      # or outside the clinic's hours, or when RPMS cannot say.
      def self.why_no_room(clinic_day, booking, resource, setup:)
        date = booking.start_time.to_date
        on = date.strftime("%b %-d, %Y")
        case clinic_day.closed
        when :beyond_booking
          limit = setup.clinic_rules(resource[:hospital_location_id])&.dig(:max_future_days)
          last = (Time.now.to_date + limit.to_i).strftime("%b %-d, %Y")
          "#{resource[:name]} books at most #{limit} #{limit.to_i == 1 ? "day" : "days"} ahead, through #{last}. #{on} is past that limit."
        when :holiday then "#{on} is a holiday, and #{resource[:name]} does not schedule on holidays."
        when :inactive then "#{resource[:name]} is inactive on #{on}."
        else prevented_block_message(clinic_day, booking, setup: setup)
        end
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] reading why a time is closed raised #{e.class}")
        nil
      end
      private_class_method :why_no_room

      # A block the clinic's hours list but booking leaves out is one whose
      # access type prevents access.
      def self.prevented_block_message(clinic_day, booking, setup:)
        start = booking.start_time
        block = clinic_day.listed_blocks.find { |b| b[:start_time] <= start && start < b[:end_time] && !clinic_day.blocks.include?(b) }
        return nil unless block

        type = Array(setup.access_types).find { |t| t[:id] == block[:access_type_id] }
        "#{start.strftime('%H:%M')} is in a #{type&.dig(:name) || 'blocked'} block, which takes no appointments."
      end
      private_class_method :prevented_block_message

      # The overbook rules (rpms-ux S-SCH-01.9 to 01.11), as the Windows
      # scheduler and BPRM apply them. Never on a day the clinic takes no
      # booking (a holiday, past its booking limit, inactive). SDZSUP or the
      # master overbook right on the resource (BSDX RESOURCE USER .06) may
      # overbook anywhere else, past the clinic's daily maximum and outside its
      # blocks. The overbook right (.03) may overbook a full time inside an
      # open block while BSDX OVERBOOK says the day is under the clinic's
      # OVERBOOKS/DAY MAXIMUM (#44 field 1918). A read that fails refuses.
      def self.overbook_permitted?(clinic_day, booking, resource, who, via:, setup:)
        return false if clinic_day.closed
        return true if who[:supervisor] || setup.master_overbook?(resource_id: resource[:id], duz: who[:duz])
        return false unless resource[:overbook] && clinic_day.in_block?(booking.start_time, booking.length)

        via.overbook_allowed(hospital_location_id: resource[:hospital_location_id], start_time: booking.start_time, resource_id: resource[:id])
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] overbook check raised #{e.class}; refused")
        false
      end
      private_class_method :overbook_permitted?

      # Marks a booked overbook. The booking stands either way; when RPMS does
      # not mark it, the result says so, so the clerk knows the clinic's
      # overbook count will miss it.
      def self.mark_overbook(booked, booking, resource, setup:)
        marked = setup.mark_overbook(hospital_location_id: resource[:hospital_location_id], start_time: booking.start_time, patient_dfn: booking.patient_dfn)
        return booked.with(status: :booked) if marked&.dig(:success)

        booked.with(message: "Booked, but RPMS did not mark it as an overbook (#{marked&.dig(:error).presence || 'no reply'}). The clinic's overbook count will miss it.")
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] overbook mark raised #{e.class}")
        booked.with(message: "Booked, but RPMS did not confirm it is marked as an overbook. The clinic's overbook count may miss it.")
      end
      private_class_method :mark_overbook

      def self.book(booking, resource, via: ::RpmsRpc::Scheduling, access_type: nil)
        reply = via.add_appointment(patient_dfn: booking.patient_dfn, resource: resource[:name],
                                    start_time: booking.start_time, end_time: booking.end_time,
                                    length_minutes: booking.length, note: booking.note, **{ access_type: access_type }.compact)
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
