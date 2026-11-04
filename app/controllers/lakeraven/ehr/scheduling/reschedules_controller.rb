# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Moving an appointment to another time, at this clinic or another one
      # the scheduler books on (rpms-ux S-SCH-02.8 to 02.10). The original is
      # cancelled with who asked and a reason, and the new appointment carries
      # its note and length. AppointmentRescheduleGateway does the two writes in
      # the order that keeps the original when the new time is refused.
      class ReschedulesController < BaseController
        before_action :load_resource!
        before_action :require_booking_right!
        before_action :load_appointment!

        # GET /scheduling/clinics/:resource_id/appointments/:appointment_id/reschedule?date=&to=&on=&whom=
        def new
          @reschedule = AppointmentReschedule.new(resource_id: params[:to].presence || @resource[:id], whom: params[:whom].presence || "PC")
          @on = params[:on].present? ? parse_date(params[:on]) : @date
          load_choices
        end

        # POST /scheduling/clinics/:resource_id/appointments/:appointment_id/reschedule
        def create
          @reschedule = AppointmentReschedule.new(reschedule_params)
          @on = @reschedule.start_time&.to_date || @date
          load_choices
          return render(:new, status: :unprocessable_content) unless @reschedule.valid? && valid_choices?

          result = AppointmentRescheduleGateway.move(
            @appointment, to_resource: @target, start_time: @reschedule.start_time, whom: @reschedule.whom,
                          reason_ien: @reschedule.reason_ien, remark: @reschedule.remark(@target[:name]),
                          overbook: { duz: session[:duz].to_i, supervisor: supervisor?, confirmed: params[:overbook] == "1" }
          )
          if result.status == :overbook_offered
            @offer_overbook = true
            return render(:new, status: :conflict)
          end

          if result.moved?
            flash[:notice] = "Moved #{@appointment[:patient_name]}'s appointment to #{@reschedule.start_time.strftime('%b %-d at %H:%M')} at #{@target[:name]}."
            flash[:booked_id] = result.appointment_id
            flash[:alert] = result.message if result.message
            redirect_to scheduling_clinic_path(@target[:id], date: @on.iso8601)
          else
            flash.now[:alert] = alert_for(result)
            render :new, status: status_for(result)
          end
        end

        private

        # The clinics this user may book on, the one moved to, its open times
        # that day at the original's length, and the reasons for who asked.
        def load_choices
          @targets = AppointmentBookingGateway.resources.select { |r| visible?(r) && can_book?(r) }
          @target = @targets.find { |r| r[:id] == @reschedule.resource_id }
          @length = AppointmentRescheduleGateway.length_of(@appointment)
          @full = []
          @times = if @target
                     day, = AppointmentBookingGateway.day(@target, @on)
                     overbookable(day)
          else
                     []
          end
          @reasons = AppointmentCancellationGateway.reasons(@reschedule.whom)
        end

        # The open times at the original's length, and for a scheduler who may
        # overbook there, the full times inside its blocks too (S-SCH-02.10).
        def overbookable(day)
          open = day.open_times(@length)
          @full = can_overbook?(@target) ? day.times.select { |t| t.open.zero? }.map(&:at).uniq - open : []
          (open + @full).sort
        end

        def valid_choices?
          @reschedule.errors.add(:resource_id, "is not a clinic you can book on") unless @target
          unless @reasons.any? { |r| r[:ien] == @reschedule.reason_ien }
            @reschedule.errors.add(:reason_ien, "is not one that can be filed when #{AppointmentCancellation::WHOM[@reschedule.whom]} asks")
          end
          @reschedule.errors.empty?
        end

        def alert_for(result)
          case result.status
          when :full then "That time is full or outside the clinic's open hours. Choose another time. The appointment was not moved."
          when :unknown then "RPMS did not confirm the move. Check both clinics' days before trying again."
          else result.message.presence || "RPMS did not move the appointment. It is still booked at its old time."
          end
        end

        def status_for(result)
          { full: :conflict, unknown: :service_unavailable, both: :conflict }.fetch(result.status, :unprocessable_content)
        end

        def require_booking_right!
          return if can_book?(@resource)

          render plain: "You cannot change appointments on #{@resource[:name]}", status: :forbidden
        end

        # The appointment, on this resource that day, and still booked (S-SCH-02.9).
        def load_appointment!
          @date = parse_date(params[:date])
          @appointment = AppointmentBookingGateway.appointment(@resource, params[:appointment_id], @date)
          return render(plain: "No such appointment on #{@resource[:name]} that day", status: :not_found) unless @appointment

          why = not_movable_because(@appointment)
          render(plain: "This appointment #{why}, so it cannot be moved.", status: :conflict) if why
        end

        def not_movable_because(appointment)
          return "is cancelled" if appointment[:cancelled]
          return "is marked no-show" if appointment[:no_show]

          "is checked in" if appointment[:checkin_time] || appointment[:checkout_time]
        end

        def reschedule_params
          params.fetch(:reschedule, {}).permit(:resource_id, :start, :whom, :reason_ien, :extra).to_h
        end
      end
    end
  end
end
