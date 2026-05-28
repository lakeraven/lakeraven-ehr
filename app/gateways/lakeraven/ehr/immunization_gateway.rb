# frozen_string_literal: true

begin
  require "rpms_rpc/api/immunization"
rescue LoadError
  # rpms-rpc gem does not yet expose the structured RpmsRpc::Immunization.
end

module Lakeraven
  module EHR
    # Patient-administered immunization records.
    # Wraps RpmsRpc::Immunization (lakeraven/rpms-rpc#107) — structured
    # records via BIPC IMMLIST / BIPC IMMGET.
    class ImmunizationGateway
      def self.for_patient(dfn, via: default_provider)
        return [] if via.nil?

        via.for_patient(dfn.to_s)
      end

      def self.find(ien, via: default_provider)
        return nil if via.nil?

        via.find(ien.to_s)
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::Immunization) &&
                          ::RpmsRpc::Immunization.respond_to?(:for_patient)
        ::RpmsRpc::Immunization
      end
    end
  end
end
