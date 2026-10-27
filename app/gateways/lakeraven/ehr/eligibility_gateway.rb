# frozen_string_literal: true

require "rpms_rpc/api/eligibility"

module Lakeraven
  module EHR
    class EligibilityGateway
      def self.patient_eligibility(dfn)
        CapabilityGuard.ensure!(:ihs_immunization)
        RpmsRpc::Eligibility.for_patient(dfn)
      end

      def self.list_codes
        CapabilityGuard.ensure!(:ihs_immunization)
        RpmsRpc::Eligibility.codes
      end
    end
  end
end
