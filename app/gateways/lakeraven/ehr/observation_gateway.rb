# frozen_string_literal: true

require "rpms_rpc/api/measurement"

module Lakeraven
  module EHR
    # Engine-side gateway over the rpms-rpc Measurement reads (the verified
    # PCC composition: ORQQVI VITALS index + DDR GETS ENTRY DATA +
    # BEHOENCX GETVISIT + BEHOVM2 VUNITS). Rows are decorated measurement
    # hashes carrying value/units/date plus the Provenance signals
    # (visit_ien, service_category, capture_mode, entered_in_error).
    class ObservationGateway
      def self.for_patient(dfn)
        RpmsRpc::Measurement.history(dfn.to_s)
      end

      # One measurement by V MEASUREMENT IEN — includes :patient_dfn so
      # id-addressed lookups (Provenance target search / show) need no
      # separate patient parameter. nil when unknown/unreadable.
      def self.find(measurement_ien)
        RpmsRpc::Measurement.find(measurement_ien)
      end
    end
  end
end
