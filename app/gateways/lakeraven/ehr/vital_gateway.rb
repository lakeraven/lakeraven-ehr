# frozen_string_literal: true

require "rpms_rpc/api/vital"

module Lakeraven
  module EHR
    # Write-side gateway for vital signs (template lookup, per-field
    # validation, bulk save). For reading existing vitals, callers should
    # use ObservationGateway.for_patient — kept as the single read entry
    # point to avoid two gateways exposing the same delegation.
    class VitalGateway
      # Field metadata for the vital-entry grid at a location.
      # Delegates to RpmsRpc::Vital.template (added in lakeraven/rpms-rpc#61).
      def self.template(location_ien)
        RpmsRpc::Vital.template(location_ien)
      end

      # Per-field server validation. Returns
      #   { valid: bool, errors: [{ index:, abbreviation:, value:, error_message: }] }
      # Delegates to RpmsRpc::Vital.validate.
      def self.validate(dfn, measurements)
        RpmsRpc::Vital.validate(dfn, measurements)
      end

      # Bulk save of measurements against an open visit. provider_duz is
      # required (matches the underlying RPC contract).
      # Delegates to RpmsRpc::Vital.add.
      def self.add(dfn, visit_string, measurements, provider_duz:)
        RpmsRpc::Vital.add(dfn, visit_string, measurements, provider_duz: provider_duz)
      end
    end
  end
end
