# frozen_string_literal: true

require "rpms_rpc/api/scheduling"

module Lakeraven
  module EHR
    # Checking a patient in (rpms-ux S-SCH-03) through BSDX CHECKIN APPOINTMENT
    # (RpmsRpc::Scheduling.checkin_appointment), which files the check-in on the
    # clinic and, for a clinic set to, the visit. Live on a built image it files
    # a check-in with no provider at a clinic that requires one, and a second
    # check-in of a checked-in appointment; so those are decided here.
    #
    # BSDX25 files the check-in (BSDXCHK) before it checks in the PIMS
    # appointment and makes the visit (APCHK), with no rollback, so an error
    # there comes back after the check-in is filed. When RPMS does not answer
    # success, the appointment is read again: a check-in time means it was
    # filed, and RPMS's message is a warning about the visit (#727).
    class AppointmentCheckinGateway
      Result = Data.define(:status, :message) do
        def checked_in? = status == :checked_in
      end

      # Whether the resource's clinic needs a visit provider named at check-in:
      # CLINIC SETUP PARAMETERS (#9009017.2) VISIT PROVIDER REQUIRED, by the
      # clinic the resource is linked to (BSDX CLINIC SETUP). Unknown counts as
      # required, so a check-in never goes ahead without one by default.
      def self.provider_required?(resource, via: ::RpmsRpc::Scheduling)
        setup = Array(via.clinic_setup).find { |c| c[:location_ien].to_i == resource[:hospital_location_id].to_i }
        setup.nil? || setup[:visit_provider_required].to_s.upcase != "NO"
      end

      # reread: returns the appointment as RPMS now has it.
      def self.check_in(appointment_id, at:, provider_ien:, reread:, via: ::RpmsRpc::Scheduling)
        result = file(appointment_id, at: at, provider_ien: provider_ien, via: via)
        return result if result.checked_in? || !filed?(reread)

        Result.new(status: :checked_in, message: result.message.presence || "RPMS did not confirm the visit.")
      end

      def self.file(appointment_id, at:, provider_ien:, via:)
        reply = via.checkin_appointment(appointment_id, checkin_time: at, provider: provider_ien)
        return Result.new(status: :unknown, message: nil) if reply.nil?
        return Result.new(status: :checked_in, message: nil) if reply[:success]

        Result.new(status: :refused, message: reply[:error].to_s)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] check-in raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, message: nil)
      end
      private_class_method :file

      def self.filed?(reread)
        reread.call&.dig(:checkin_time).present?
      rescue ::RpmsRpc::Error, IOError, SystemCallError
        false
      end
      private_class_method :filed?
    end
  end
end
