# frozen_string_literal: true

module Lakeraven
  module EHR
    # Runs another eligibility check after the client gave up on a transient
    # failure. The arguments include a patient identifier, so they are not
    # written to the log. The bearer token is not an argument.
    #
    # The check always uses the currently configured endpoint, with
    # schedule_retry disabled: a copy of the configured EnrollmentFHIRClient
    # when that is the adapter, otherwise a client built from the
    # environment. The copy keeps that client's transport and cache. A
    # queued base_url is not a host to call. When it is present and differs
    # from the configured endpoint, the job logs a fixed line and does not
    # send the request. A still-pending result raises Unavailable so Active
    # Job can retry. On the final attempt the job logs a fixed line and
    # stops. perform_now leaves that retry with Active Job and does not
    # re-raise it. An error outcome is logged and not raised. The job never
    # records enrolled or not_enrolled on its own.
    class EnrollmentEligibilityRetryJob < ApplicationJob
      queue_as :integrations

      self.log_arguments = false

      MAX_ATTEMPTS = 5

      retry_on EnrollmentFHIRClient::Unavailable, wait: :polynomially_longer, attempts: MAX_ATTEMPTS

      ENDPOINT_CHANGED = "Enrollment eligibility retry skipped: endpoint changed"

      def perform(patient_dfn:, coverage_type:, service_date: nil, provider_npi: nil, purpose: nil, base_url: nil)
        client = configured_fhir_client
        return log_unconfigured unless client
        return log_endpoint_changed unless client.current_endpoint?(base_url)

        result = client.for_retry.check_eligibility(
          eligibility_request(patient_dfn, coverage_type, service_date, provider_npi, purpose)
        )
        handle_outcome(result)
      end

      private

      def configured_fhir_client
        adapter = Lakeraven::EHR.configuration.eligibility_adapter
        return adapter if adapter.is_a?(EnrollmentFHIRClient)

        EnrollmentFHIRClient.from_environment
      end

      def log_endpoint_changed
        Rails.logger.error(ENDPOINT_CHANGED)
      end

      def eligibility_request(patient_dfn, coverage_type, service_date, provider_npi, purpose)
        CoverageEligibilityRequest.new(
          patient_dfn: patient_dfn,
          coverage_type: coverage_type,
          service_date: service_date,
          provider_npi: provider_npi,
          purpose: purpose.presence || "benefits"
        )
      end

      def handle_outcome(result)
        return if result.enrolled? || result.not_enrolled?
        return log_error_outcome if result.error?

        exhaust_or_raise if result.pending?
      end

      def exhaust_or_raise
        if executions.to_i >= MAX_ATTEMPTS
          log_exhausted
        else
          raise EnrollmentFHIRClient::Unavailable
        end
      end

      def log_unconfigured
        Rails.logger.error("Enrollment eligibility retry skipped: client is not configured")
      end

      def log_error_outcome
        Rails.logger.error("Enrollment eligibility retry received error outcome")
      end

      def log_exhausted
        Rails.logger.error("Enrollment eligibility retry exhausted without terminal outcome")
      end
    end
  end
end
