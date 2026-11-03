# frozen_string_literal: true

require "rpms_rpc/api/eligibility"
require "rpms_rpc/api/immunization_lot"

module Lakeraven
  module EHR
    class EligibilityGateway
      # VACCINE SOURCE (#9999999.41 .13) internal code for a VFC lot.
      VFC_SOURCE = "v"

      def self.patient_eligibility(dfn)
        CapabilityGuard.ensure!(:ihs_immunization)
        RpmsRpc::Eligibility.for_patient(dfn)
      end

      def self.list_codes
        CapabilityGuard.ensure!(:ihs_immunization)
        RpmsRpc::Eligibility.codes
      end

      # One vaccine lot, for the VFC check (VfcEligibilityEnforcementService):
      # { ien:, lot_number:, vaccine_code: (CVX), funding_source: "VFC" or the
      # source's label, active:, expiration_date: }, or nil when RPMS has no
      # such lot. Read from IMMUNIZATION LOT (RpmsRpc::ImmunizationLot), the
      # only place the lot's VACCINE SOURCE is kept.
      def self.find_lot(lot_ien, via: ::RpmsRpc::ImmunizationLot)
        CapabilityGuard.ensure!(:ihs_immunization)
        lot = via.find(lot_ien)
        lot && vfc_lot(lot)
      end

      # Every lot on file, in find_lot's shape. Raises when RPMS gives no
      # answer, so a check never mistakes an outage for an empty lot list.
      def self.list_lots(via: ::RpmsRpc::ImmunizationLot)
        CapabilityGuard.ensure!(:ihs_immunization)
        lots = via.list
        raise RpmsRpc::Client::RpcError, "IMMUNIZATION LOT could not be listed" if lots.nil?

        lots.map { |lot| vfc_lot(lot) }
      end

      def self.vfc_lot(lot)
        { ien: lot[:ien], lot_number: lot[:lot_number], vaccine_code: lot[:cvx],
          funding_source: lot[:source] == VFC_SOURCE ? "VFC" : lot[:source_label],
          active: lot[:active], expiration_date: lot[:expiration_date] }
      end
      private_class_method :vfc_lot
    end
  end
end
