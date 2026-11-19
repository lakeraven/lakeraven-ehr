# frozen_string_literal: true

require "rpms_rpc/api/scheduling_setup"

module Lakeraven
  module EHR
    # Existing clinic provider entries, read and changed in RPMS.
    class ClinicProvidersGateway
      def self.read(resource, setup: ::RpmsRpc::SchedulingSetup)
        providers = setup.clinic_providers(resource[:hospital_location_id])
        return unless providers.is_a?(Array) && providers.all? do |provider|
          provider.is_a?(Hash) && provider[:id].is_a?(Integer) && provider[:id].positive? &&
            provider[:duz].is_a?(Integer) && provider[:duz].positive? && provider[:name].is_a?(String) &&
            provider[:name].present? && [ true, false ].include?(provider[:default])
        end
        return unless providers.map { |provider| provider[:id] }.uniq.size == providers.size

        providers
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] reading clinic providers raised #{e.class}")
        nil
      end

      def self.change(resource, entry_id, action, setup: ::RpmsRpc::SchedulingSetup)
        providers = read(resource, setup: setup)
        return :unknown unless providers
        return :missing unless providers.any? { |provider| provider[:id].to_i == entry_id.to_i }

        clinic = resource[:hospital_location_id]
        outcome = if action == :default
          setup.set_default_provider(hospital_location_id: clinic, entry_id: entry_id.to_i)
        else
          setup.remove_clinic_provider(hospital_location_id: clinic, entry_id: entry_id.to_i)
        end
        return :unknown unless outcome.is_a?(Hash) && outcome[:success] == true

        current = read(resource, setup: setup)
        return :unknown unless current

        confirmed = if action == :default
          current.select { |provider| provider[:default] }.map { |provider| provider[:id].to_i } == [ entry_id.to_i ]
        else
          current.none? { |provider| provider[:id].to_i == entry_id.to_i }
        end
        confirmed ? :saved : :unknown
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] changing clinic providers raised #{e.class}; the outcome is unknown")
        :unknown
      end
    end
  end
end
