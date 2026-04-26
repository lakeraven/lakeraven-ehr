# frozen_string_literal: true

module Lakeraven
  module EHR
    # AlternateResourceService - Validates that services are not available at IHS facilities.
    # PRC/CHS requires documentation that service cannot be provided by IHS.
    class AlternateResourceService
      class_attribute :terminology_service, default: nil

      VALUESET_IHS_AVAILABLE = "ihs-available-services"
      VALUESET_SPECIALIZED_SERVICES = "prc-specialized-services"

      IHS_AVAILABLE_SERVICES = [
        "Primary Care", "Family Medicine", "Internal Medicine", "General Surgery",
        "Pediatrics", "Obstetrics", "Emergency Medicine", "Dental"
      ].freeze

      UNAVAILABLE_KEYWORDS = [
        "not available at IHS", "not available at ihs", "unavailable at IHS",
        "IHS does not have", "IHS facility does not have", "not staffed at IHS",
        "specialized expertise", "subspecialty"
      ].freeze

      WAIT_TIME_KEYWORDS = [
        "wait time", "waiting time", "exceeds clinical appropriateness",
        "on leave", "not immediately available"
      ].freeze

      INVALID_KEYWORDS = [ "patient prefers", "patient wants", "patient requests" ].freeze

      def self.check(service_request)
        AlternateResourceResult.new(service_request)
      end
    end

    class AlternateResourceResult
      attr_reader :service_request, :justification_keywords, :denial_reasons

      def initialize(service_request)
        @service_request = service_request
        @justification_keywords = []
        @denial_reasons = []
        analyze_justification
      end

      def service_unavailable_at_ihs?
        justification = service_request.alternate_resource_justification
        if justification.present?
          if justification.is_a?(Integer) && [ 0, 3, 4 ].include?(justification)
            @justification_keywords << service_request.alternate_resource_justification_symbol.to_s
            return true
          end
        end

        reason = service_request.reason_for_referral&.downcase || ""
        found = false

        AlternateResourceService::UNAVAILABLE_KEYWORDS.each do |keyword|
          if reason.include?(keyword.downcase)
            @justification_keywords << keyword unless @justification_keywords.include?(keyword)
            found = true
          end
        end

        if reason.include?("not available") || reason.include?("not immediately available")
          @justification_keywords << "not available" unless @justification_keywords.include?("not available")
          found = true
        end

        found
      end

      def specialty_expertise_required?
        justification = service_request.alternate_resource_justification
        if justification == 1 # specialized_expertise
          @justification_keywords << service_request.alternate_resource_justification_symbol.to_s
          return true
        end

        service = service_request.service_requested&.downcase || ""
        reason = service_request.reason_for_referral&.downcase || ""

        specialized = %w[neurosurgery interventional\ cardiology cardiac\ surgery radiation\ oncology transplant specialized subspecialty]

        specialized.any? do |spec|
          if service.include?(spec) || reason.include?(spec)
            @justification_keywords << spec unless @justification_keywords.include?(spec)
            true
          end
        end
      end

      def valid_alternate_resource_reason?
        return @valid_reason unless @valid_reason.nil?

        reason = service_request.reason_for_referral&.downcase || ""

        AlternateResourceService::INVALID_KEYWORDS.each do |invalid|
          if reason.include?(invalid.downcase)
            @denial_reasons << "Patient preference alone is not sufficient justification"
            @valid_reason = false
            return false
          end
        end

        if service_unavailable_at_ihs? || specialty_expertise_required? || wait_time_justification? || emergency_alternate_resource?
          @valid_reason = true
          return true
        end

        if service_available_at_ihs?
          @denial_reasons << "Service appears to be available at IHS facility"
          @valid_reason = false
          return false
        end

        @denial_reasons << "Insufficient justification for external referral"
        @valid_reason = false
        false
      end

      def service_available_at_ihs?
        service = service_request.service_requested || ""
        return false if service.blank?

        ts = AlternateResourceService.terminology_service
        if ts
          begin
            codes = ts.expand_valueset(AlternateResourceService::VALUESET_IHS_AVAILABLE)
            return codes.any? { |c| c[:display] == service || c[:code] == service }
          rescue StandardError
            # Fall through to constant-based check
          end
        end

        AlternateResourceService::IHS_AVAILABLE_SERVICES.any? { |ihs_service| service == ihs_service }
      end

      def wait_time_justification?
        justification = service_request.alternate_resource_justification
        if justification == 2 # wait_time_exceeds
          @justification_keywords << service_request.alternate_resource_justification_symbol.to_s
          return true
        end

        reason = service_request.reason_for_referral&.downcase || ""
        found = false

        AlternateResourceService::WAIT_TIME_KEYWORDS.each do |keyword|
          if reason.include?(keyword.downcase)
            @justification_keywords << keyword unless @justification_keywords.include?(keyword)
            found = true
          end
        end
        found
      end

      def emergency_alternate_resource?
        service_request.emergent? && (service_unavailable_at_ihs? || wait_time_justification?)
      end

      def urgency_supports_alternate_resource?
        (service_request.emergent? || service_request.urgent?) &&
          (service_unavailable_at_ihs? || wait_time_justification?)
      end

      def documentation_complete?
        if service_request.alternate_resource_justification.present?
          return service_request.service_requested.present? &&
                 service_request.service_requested.length >= 5 &&
                 service_request.reason_for_referral.present?
        end

        reason = service_request.reason_for_referral || ""
        service = service_request.service_requested || ""

        return false if reason.length < 20
        return false if service.length < 5

        specific_service_identified? && ihs_limitation_documented?
      end

      def specific_service_identified?
        service = service_request.service_requested || ""
        service.length >= 5 && service != "Specialty"
      end

      def ihs_limitation_documented?
        reason = service_request.reason_for_referral&.downcase || ""
        reason.include?("ihs") || reason.include?("facility") ||
          service_unavailable_at_ihs? || specialty_expertise_required?
      end

      def inpatient_justification_adequate?
        return true if service_request.referral_type != "INPATIENT"
        service_unavailable_at_ihs? && documentation_complete?
      end

      def compliant?
        valid_alternate_resource_reason? && denial_reasons.empty?
      end

      def message
        return denial_reasons.join("; ") if denial_reasons.any?

        if !documentation_complete?
          return "Referral documentation incomplete - insufficient detail provided"
        end

        messages = []
        messages << "Service documented as not available at IHS facility" if service_unavailable_at_ihs?
        messages << "Specialized expertise not available at IHS" if specialty_expertise_required?
        messages << "Wait time exceeds clinical appropriateness" if wait_time_justification?
        messages << "Emergency alternate resource justified" if emergency_alternate_resource?

        if messages.empty?
          valid_alternate_resource_reason? ? "Alternate resource justification accepted" : "Insufficient justification for external referral"
        else
          messages.join("; ")
        end
      end

      private

      def analyze_justification
        service_unavailable_at_ihs?
        specialty_expertise_required?
        wait_time_justification?
      end
    end
  end
end
