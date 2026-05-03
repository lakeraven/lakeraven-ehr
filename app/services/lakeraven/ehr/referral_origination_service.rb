# frozen_string_literal: true

module Lakeraven
  module EHR
    # Orchestrates referral creation from the EHR side.
    # Validates the ServiceRequest and optionally pre-checks enrollment
    # as clinical context for the ordering clinician.
    #
    # Enrollment pre-check is informational — it does not block the referral.
    # If corvid is present, corvid enforces enrollment via the eligibility
    # checklist. EHR-only customers still benefit from seeing enrollment
    # status at point of referral.
    #
    # The EHR does NOT call corvid directly — it returns an origination result
    # that the host app uses to create the PrcReferral via corvid's adapter.
    class ReferralOriginationService
      OriginationResult = Struct.new(
        :success, :service_request, :patient_identifier,
        :enrollment_status, :errors,
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

        OriginationResult.new(
          success: true,
          service_request: sr,
          patient_identifier: patient_dfn.to_s,
          enrollment_status: check_enrollment(patient_dfn),
          errors: []
        )
      end

      private

      def check_enrollment(patient_dfn)
        return nil unless @enrollment_checker

        result = @enrollment_checker.call(patient_dfn)
        { verified: result[:enrolled] || false, tribe_name: result[:tribe_name] }
      rescue
        nil
      end
    end
  end
end
