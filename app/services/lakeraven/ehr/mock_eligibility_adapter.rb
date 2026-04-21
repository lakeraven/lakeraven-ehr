# frozen_string_literal: true

module Lakeraven
  module EHR
    # Default mock adapter for eligibility checks.
    # Returns "enrolled" with a 1-year coverage period.
    # Used in tests and development when no clearinghouse is configured.
    class MockEligibilityAdapter
      def call(request)
        CoverageEligibilityResponse.new(
          patient_dfn: request.patient_dfn,
          coverage_type: request.coverage_type,
          status: "enrolled",
          plan_name: "Mock Plan",
          insurer_name: "Mock Insurer",
          start_date: 1.year.ago.to_date,
          end_date: 1.year.from_now.to_date
        )
      end
    end
  end
end
