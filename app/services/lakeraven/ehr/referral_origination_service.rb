# frozen_string_literal: true

module Lakeraven
  module EHR
    # Orchestrates referral creation from the EHR side.
    # Creates the ServiceRequest and prepares handoff data for the PRC engine.
    #
    # The EHR does NOT call corvid directly — it returns an origination result
    # that the host app uses to create the PrcReferral via corvid's adapter.
    class ReferralOriginationService
      OriginationResult = Struct.new(
        :success, :service_request, :patient_identifier, :enrollment_status,
        :coverage_summary, :errors,
        keyword_init: true
      ) do
        def success? = success
      end

      def initialize(enrollment_checker: nil)
        @enrollment_checker = enrollment_checker
      end

      def originate(patient_dfn:, provider_ien:, params:)
        sr = ServiceRequest.new(
          patient_dfn: patient_dfn.to_i,
          requesting_provider_ien: provider_ien.to_i,
          service_requested: params[:service_requested],
          urgency: params[:urgency],
          reason_for_referral: params[:reason_for_referral],
          status: "draft"
        )

        unless sr.valid?
          return OriginationResult.new(
            success: false, errors: sr.errors.full_messages
          )
        end

        enrollment = check_enrollment(patient_dfn)
        coverage = check_coverage(patient_dfn)

        OriginationResult.new(
          success: true,
          service_request: sr,
          patient_identifier: patient_dfn.to_s,
          enrollment_status: enrollment,
          coverage_summary: coverage,
          errors: []
        )
      end

      private

      def check_enrollment(patient_dfn)
        return { verified: false } unless @enrollment_checker

        result = @enrollment_checker.call(patient_dfn)
        { verified: result[:enrolled] || false, tribe_name: result[:tribe_name] }
      rescue
        { verified: false }
      end

      def check_coverage(patient_dfn)
        return {} unless @coverage_checker

        @coverage_checker.call(patient_dfn)
      rescue
        {}
      end
    end
  end
end
