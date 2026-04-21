# frozen_string_literal: true

module Lakeraven
  module EHR
    # Orchestrates an eligibility check via the configured adapter.
    #
    #   result = EligibilityCheck.call(request)
    #   result.enrolled?  # => true/false
    #
    # The adapter is pluggable — configure it in the host app:
    #
    #   Lakeraven::EHR.configure do |c|
    #     c.eligibility_adapter = StediEligibilityAdapter.new
    #   end
    #
    # The adapter must respond to #call(CoverageEligibilityRequest)
    # and return a CoverageEligibilityResponse.
    class EligibilityCheck
      class InvalidRequestError < StandardError; end

      def self.call(request)
        raise InvalidRequestError, request.errors.full_messages.join(", ") unless request.valid?

        adapter = Lakeraven::EHR.configuration.eligibility_adapter
        adapter.call(request)
      end
    end
  end
end
