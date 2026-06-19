# frozen_string_literal: true

require "rpms_rpc/api/measurement"

module Lakeraven
  module EHR
    # PCC measurement entry (height, weight, BMI, etc.) against an open
    # encounter. Distinct from clinical vitals (VitalGateway / BEHOVM).
    # Wraps RpmsRpc::Measurement 
    class MeasurementGateway
      FAILURE = { success: false, ien: nil, raw: nil }.freeze

      def self.add(dfn, visit_ien, measurement_type, value, units:, qualifier: nil, via: default_provider)
        return FAILURE if via.nil?

        via.add(dfn.to_s, visit_ien.to_s, measurement_type, value,
          units: units, qualifier: qualifier)
      end

      def self.default_provider
        ::RpmsRpc::Measurement
      end
    end
  end
end
