# frozen_string_literal: true

require "rpms_rpc/api/scheduling_setup"

module Lakeraven
  module EHR
    # A clinic's scheduling settings (rpms-ux S-SCH-15) through
    # RpmsRpc::SchedulingSetup: its HOSPITAL LOCATION (#44) and CLINIC SETUP
    # PARAMETERS (#9009017.2) fields, read with DDR GETS ENTRY DATA and filed
    # field by field with DDR FILER, where FileMan applies each field's own
    # input transform and screen. Nothing is kept here: the next booking reads
    # the clinic's rules again, so a change applies to it without signing out
    # (S-SCH-15.7).
    class ClinicSettingsGateway
      # status: :saved, :unchanged, :refused (refused maps each setting FileMan
      # did not file to its message; the others were filed) or :unknown (RPMS
      # did not answer). warning: why check-in may not create a proper visit,
      # read from what RPMS holds after the save, or nil (S-SCH-15.3).
      Result = Data.define(:status, :refused, :warning)

      DEFAULT_PROVIDER_WARNING = "Check-in creates a visit and requires a visit provider, but this clinic has no default provider. " \
                                 "Check-in will ask for one each time until a default provider is set."

      def self.read(resource, setup: ::RpmsRpc::SchedulingSetup)
        setup.clinic_settings(resource[:hospital_location_id])
      end

      # The letters of each type, for the clinic's four letter choices.
      def self.letters(setup: ::RpmsRpc::SchedulingSetup)
        Array(setup.letters).group_by { |l| l[:type] }
      end

      # The clinic codes a clinic may carry: the active CLINIC STOPs.
      def self.clinic_codes(setup: ::RpmsRpc::SchedulingSetup, today: Date.today)
        Array(setup.clinic_stops).reject { |s| s[:inactive_date] && s[:inactive_date] <= today }.sort_by { |s| s[:name].to_s }
      end

      def self.save(form, resource, setup: ::RpmsRpc::SchedulingSetup)
        clinic = resource[:hospital_location_id]
        changes = form.changes_from(setup.clinic_settings(clinic))
        return Result.new(status: :unchanged, refused: {}, warning: warning(setup.clinic_settings(clinic))) if changes.empty?

        outcome = setup.update_clinic_settings(clinic, changes)
        return Result.new(status: :unknown, refused: {}, warning: nil) if outcome.nil?

        status = outcome[:success] ? :saved : :refused
        Result.new(status: status, refused: outcome[:refused] || {}, warning: warning(setup.clinic_settings(clinic)))
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] saving clinic settings raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, refused: {}, warning: nil)
      end

      # Check-in creates the visit (CHECKIN^BSDX25) and requires its provider,
      # and no provider is the clinic's default: S-SCH-15.3.
      def self.warning(settings)
        return nil unless settings && settings[:create_visit_at_checkin] && settings[:visit_provider_required]
        return nil if Array(settings[:providers]).any? { |p| p[:default] }

        DEFAULT_PROVIDER_WARNING
      end
    end
  end
end
