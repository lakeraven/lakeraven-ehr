# frozen_string_literal: true

module Lakeraven
  module EHR
    # EnrollmentVerificationService - Verifies patient enrollment in alternate resources.
    # Checks eligibility with external payer systems per 42 CFR 136.61.
    class EnrollmentVerificationService
      VerificationResult = Struct.new(
        :resource_type, :status, :enrolled, :payer_name,
        :policy_number, :group_number, :coverage_start, :coverage_end,
        :response_data, :error,
        keyword_init: true
      ) do
        def success?
          error.nil?
        end

        def enrolled?
          enrolled == true
        end
      end

      ADAPTERS = {
        "medicare_a" => :medicare_adapter,
        "medicare_b" => :medicare_adapter,
        "medicare_d" => :medicare_adapter,
        "medicaid" => :medicaid_adapter,
        "va_benefits" => :va_adapter,
        "private_insurance" => :private_insurance_adapter,
        "workers_comp" => :generic_adapter,
        "auto_insurance" => :generic_adapter,
        "liability_coverage" => :generic_adapter,
        "state_program" => :generic_adapter,
        "tribal_program" => :tribal_adapter,
        "charity_care" => :generic_adapter
      }.freeze

      RESOURCE_TYPES = ADAPTERS.keys.freeze

      attr_reader :patient, :patient_dfn

      def initialize(patient_or_dfn)
        if patient_or_dfn.is_a?(Patient)
          @patient = patient_or_dfn
          @patient_dfn = patient_or_dfn.dfn.to_s
        else
          @patient_dfn = patient_or_dfn.to_s
          @patient = nil
        end
      end

      def verify(resource_type)
        resource_type = resource_type.to_s
        adapter_method = ADAPTERS[resource_type] || :generic_adapter

        begin
          send(adapter_method, resource_type)
        rescue => e
          sanitized_msg = PhiSanitizer.sanitize_message(e.message)
          Rails.logger.error("Enrollment verification failed for #{resource_type}: #{sanitized_msg}")
          VerificationResult.new(
            resource_type: resource_type,
            status: :not_checked,
            enrolled: nil,
            error: sanitized_msg
          )
        end
      end

      def verify_all
        RESOURCE_TYPES.map { |resource_type| verify(resource_type) }
      end

      private

      def medicare_adapter(resource_type)
        # Real implementation would call MedicareEligibilityClient
        raise NotImplementedError, "Medicare eligibility check requires configured adapter"
      end

      def medicaid_adapter(resource_type)
        raise NotImplementedError, "Medicaid eligibility check requires configured adapter"
      end

      def va_adapter(resource_type)
        raise NotImplementedError, "VA benefits check requires configured adapter"
      end

      def private_insurance_adapter(resource_type)
        VerificationResult.new(
          resource_type: resource_type,
          status: :not_checked,
          enrolled: nil,
          response_data: { message: "Private insurance requires manual verification" }
        )
      end

      def tribal_adapter(resource_type)
        VerificationResult.new(
          resource_type: resource_type,
          status: patient&.tribal_enrollment_number.present? ? :enrolled : :not_enrolled,
          enrolled: patient&.tribal_enrollment_number.present?,
          payer_name: "Tribal Health Program",
          policy_number: patient&.tribal_enrollment_number,
          response_data: { tribal_affiliation: patient&.tribal_affiliation }
        )
      end

      def generic_adapter(resource_type)
        VerificationResult.new(
          resource_type: resource_type,
          status: :not_checked,
          enrolled: nil,
          response_data: { message: "Manual verification required for #{resource_type}" }
        )
      end

      def part_name(resource_type)
        case resource_type
        when "medicare_a" then "Part A (Hospital)"
        when "medicare_b" then "Part B (Medical)"
        when "medicare_d" then "Part D (Prescription)"
        else "Part A"
        end
      end
    end
  end
end
