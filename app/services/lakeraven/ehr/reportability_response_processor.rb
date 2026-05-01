# frozen_string_literal: true

module Lakeraven
  module EHR
    # Processes Reportability Response (RR) from public health agencies.
    # ONC § 170.315(f)(5) — Electronic Case Reporting
    class ReportabilityResponseProcessor
      VALID_DETERMINATIONS = %w[reportable not\ reportable may\ be\ reportable no\ rule\ met].freeze

      def self.process(eicr_id:, patient_dfn:, determination:, jurisdiction:)
        {
          success: true,
          eicr_id: eicr_id,
          patient_dfn: patient_dfn,
          determination: determination,
          jurisdiction: jurisdiction,
          processed_at: Time.current
        }
      end
    end
  end
end
