# frozen_string_literal: true

module Lakeraven
  module EHR
    # VFC (Vaccines for Children) eligibility via RPMS RPCs.
    # Used for vaccine lot enforcement — fail-closed check before
    # administering VFC-funded vaccines.
    class VfcEligibility
      VFC_ELIGIBLE_CODES = %w[V02 V03 V04 V05 V06 V07].freeze

      def self.patient_eligibility(dfn)
        EligibilityGateway.patient_eligibility(dfn)
      end

      def self.list_codes
        EligibilityGateway.list_codes
      end

      def self.eligible?(code)
        VFC_ELIGIBLE_CODES.include?(code.to_s)
      end
    end
  end
end
