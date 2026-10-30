# frozen_string_literal: true

module Lakeraven
  module EHR
    # Runs another eligibility check after the client gave up on a transient
    # failure. The arguments include a patient identifier, so they are not
    # written to the log. The bearer token is not an argument; the client
    # reads LAKERAVEN_ENROLLMENT_FHIR_TOKEN when the job builds it.
    #
    # A still-pending result is raised so Active Job retries. The job never
    # records enrolled or not_enrolled on its own.
    class EnrollmentEligibilityRetryJob < ApplicationJob
      queue_as :integrations

      self.log_arguments = false

      retry_on EnrollmentFHIRClient::Unavailable, wait: :polynomially_longer, attempts: 5

      def perform(patient_dfn:, coverage_type:, service_date: nil, provider_npi: nil, purpose: nil, base_url: nil)
        client = EnrollmentFHIRClient.from_environment(base_url: base_url)
        return log_unconfigured unless client

        result = client.check_eligibility(eligibility_request(patient_dfn, coverage_type, service_date, provider_npi, purpose))
        raise EnrollmentFHIRClient::Unavailable if result.pending?
      end

      private

      def eligibility_request(patient_dfn, coverage_type, service_date, provider_npi, purpose)
        CoverageEligibilityRequest.new(
          patient_dfn: patient_dfn,
          coverage_type: coverage_type,
          service_date: service_date,
          provider_npi: provider_npi,
          purpose: purpose.presence || "benefits"
        )
      end

      def log_unconfigured
        Rails.logger.error("Enrollment eligibility retry skipped: client is not configured")
      end
    end
  end
end
