# frozen_string_literal: true

module Lakeraven
  module EHR
    class PrcEligibilityRuleset
      VALID_SERVICE_AREAS = %w[Anchorage Fairbanks Juneau Bethel Nome Barrow Sitka Ketchikan].freeze
      CLINICAL_KEYWORDS = %w[chest pain cardiac surgery fracture injury urgent severe chronic failed treatment].freeze
      VALID_COVERAGE_TYPES = [ "IHS", "Medicare/IHS", "Private Insurance/IHS", "Medicaid/IHS" ].freeze

      def is_eligible(is_tribally_enrolled, meets_residency, has_clinical_necessity, has_payor_coordination)
        is_tribally_enrolled && meets_residency && has_clinical_necessity && has_payor_coordination
      end

      def is_tribally_enrolled(enrollment_number)
        return false if enrollment_number.nil? || enrollment_number.to_s.strip.empty?
        enrollment_number.to_s.match?(/^[A-Z]+-\d+$/)
      end

      def meets_residency(service_area)
        VALID_SERVICE_AREAS.include?(service_area)
      end

      def has_clinical_necessity(has_clinical_justification, urgency_appropriate)
        has_clinical_justification && urgency_appropriate
      end

      def has_clinical_justification(reason_for_referral)
        return false if reason_for_referral.nil? || reason_for_referral.to_s.strip.empty?
        reason_text = reason_for_referral.to_s.downcase
        CLINICAL_KEYWORDS.any? { |keyword| reason_text.include?(keyword) }
      end

      def urgency_appropriate(reason_for_referral, urgency, has_clinical_justification)
        return false unless has_clinical_justification
        return false if reason_for_referral.nil? || reason_for_referral.to_s.strip.empty?
        return true if urgency == :routine

        reason_text = reason_for_referral.to_s.downcase

        case urgency
        when :emergent
          reason_text.include?("emergent") || reason_text.include?("chest pain") || reason_text.include?("severe")
        when :urgent
          reason_text.include?("urgent") || reason_text.include?("chest pain") || reason_text.include?("cardiac")
        else
          false
        end
      end

      def has_payor_coordination(coverage_type)
        VALID_COVERAGE_TYPES.include?(coverage_type&.strip)
      end

      def self.message_for(fact_name, value, context = {})
        case fact_name.to_sym
        when :is_tribally_enrolled
          value ? "Valid tribal enrollment: #{context[:enrollment_number]}" : "Invalid or missing tribal enrollment number"
        when :meets_residency
          value ? "Patient resides in valid service area: #{context[:service_area]}" : "Patient service area '#{context[:service_area]}' is outside coverage region"
        when :has_clinical_justification
          if value
            "Clinical justification documented"
          elsif context[:reason_for_referral].to_s.strip.empty?
            "Clinical reason for service request is required"
          else
            "Insufficient clinical justification for specialty service request"
          end
        when :urgency_appropriate
          value ? "Urgency level appropriate for clinical presentation" : "Urgency level does not match clinical presentation"
        when :has_clinical_necessity
          if value
            urgency_str = context[:urgency].to_s.upcase
            "Clinical necessity documented: #{urgency_str} service request for #{context[:service_requested]}"
          elsif context[:reason_for_referral].to_s.strip.empty?
            "Clinical reason for service request is required"
          elsif !context[:has_clinical_justification]
            "Insufficient clinical justification for specialty service request"
          else
            "Urgency level does not match clinical presentation"
          end
        when :has_payor_coordination
          coverage = context[:coverage_type]&.strip
          if value
            case coverage
            when "IHS" then "IHS is primary payor - no coordination required"
            when "Medicare/IHS" then "Medicare is primary payor - IHS will coordinate as secondary"
            when "Private Insurance/IHS" then "Private insurance is primary - IHS will coordinate as secondary"
            when "Medicaid/IHS" then "Medicaid is primary payor - IHS will coordinate as secondary"
            else "Valid payor coordination"
            end
          else
            "Unknown or invalid coverage type: #{coverage}"
          end
        when :is_eligible
          value ? "Patient is eligible for PRC services" : "Patient is not eligible for PRC services"
        else
          "#{fact_name}: #{value}"
        end
      end
    end
  end
end
