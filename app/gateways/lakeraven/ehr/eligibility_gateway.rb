# frozen_string_literal: true

require "rpms_rpc/api/eligibility"

module Lakeraven
  module EHR
    class EligibilityGateway
      def self.patient_eligibility(dfn)
        RpmsRpc::Eligibility.for_patient(dfn)
      end

      def self.list_codes
        RpmsRpc::Eligibility.codes
      end
    end
  end
end
