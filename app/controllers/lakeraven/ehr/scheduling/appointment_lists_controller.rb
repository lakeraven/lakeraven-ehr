# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # The appointments across the scheduler's clinics (rpms-ux S-SCH-05.5):
      # today's, future, past or all of them, kept to one status if asked and
      # sorted by a column. The clinics are the ones scheduling offers this user
      # (BaseController#visible?). Each links to its clinic's day, where it is
      # acted on.
      class AppointmentListsController < BaseController
        # How far future, past and all reach, each way: BSDX reads a range.
        REACH_DAYS = 90
        WHEN = { "today" => "Today", "future" => "Future", "past" => "Past", "all" => "All" }.freeze
        STATUSES = { "booked" => "Booked", "checked" => "Checked in", "checked-out" => "Checked out",
                     "no-show" => "No-show", "cancelled" => "Cancelled" }.freeze
        SORTS = { "time" => "Appointment time", "patient" => "Patient", "checkin" => "Check-in", "checkout" => "Check-out" }.freeze

        rate_limit only: :index

        # GET /scheduling/appointments?when=&status=&sort=
        def index
          @when = params[:when].presence_in(WHEN.keys) || "today"
          @status = params[:status].presence_in(STATUSES.keys)
          @sort = params[:sort].presence_in(SORTS.keys) || "time"
          @appointments = read_appointments
        end

        private

        def range
          today = Date.today
          case @when
          when "today" then today..today
          when "future" then (today + 1)..(today + REACH_DAYS)
          when "past" then (today - REACH_DAYS)..(today - 1)
          else (today - REACH_DAYS)..(today + REACH_DAYS)
          end
        end

        # The rows, or :unread when RPMS does not answer: a failed read is said
        # so, never shown as an empty list.
        def read_appointments
          resources = AppointmentBookingGateway.resources.select { |r| visible?(r) }
          listed = AppointmentBookingGateway.listed(resources, range)
          sorted(listed.select { |a| @status.nil? || helpers.appointment_status(a).first == @status })
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          Rails.logger.error("[scheduling] the appointment list raised #{e.class}")
          :unread
        end

        def sorted(rows)
          case @sort
          when "patient" then rows.sort_by { |a| [ a[:patient_name].to_s, a[:start_time] ] }
          when "checkin" then by_time(rows, :checkin_time)
          when "checkout" then by_time(rows, :checkout_time)
          else rows.sort_by { |a| a[:start_time] }
          end
        end

        # Earliest first, those with no such time after them.
        def by_time(rows, key)
          rows.sort_by { |a| [ a[key] ? 0 : 1, a[key] || a[:start_time] ] }
        end
      end
    end
  end
end
