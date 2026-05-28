# frozen_string_literal: true

begin
  require "rpms_rpc/api/immunization_refusal"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::ImmunizationRefusal.
end

module Lakeraven
  module EHR
    # Records a patient's refusal of an immunization on the open encounter.
    # Distinct from ImmunizationGateway (read-only).
    # Wraps RpmsRpc::ImmunizationRefusal (lakeraven/rpms-rpc#76).
    class ImmunizationRefusalGateway
      FAILURE = { success: false, ien: nil, raw: nil }.freeze

      def self.record(dfn, vaccine_code, reason_code:, narrative: nil, via: default_provider)
        return FAILURE if via.nil?

        via.record(dfn.to_s, vaccine_code,
          reason_code: reason_code, narrative: narrative)
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::ImmunizationRefusal) &&
                          ::RpmsRpc::ImmunizationRefusal.respond_to?(:record)
        ::RpmsRpc::ImmunizationRefusal
      end
    end
  end
end
