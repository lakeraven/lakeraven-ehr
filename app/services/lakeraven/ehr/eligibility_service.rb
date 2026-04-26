# frozen_string_literal: true

module Lakeraven
  module EHR
    # PRC Eligibility Service — evaluates eligibility rules for Purchased/Referred Care.
    class EligibilityService
      include StructuredLogging

      FACT_TO_CHECK_NAME = {
        is_tribally_enrolled: :tribal_enrollment,
        meets_residency: :residency,
        has_clinical_necessity: :clinical_necessity,
        has_payor_coordination: :payor_coordination
      }.freeze

      def self.check(service_request)
        new(service_request).check
      end

      def initialize(service_request)
        @service_request = service_request
        @patient = service_request.patient
        @engine = RulesEngine.new(PrcEligibilityRuleset.new)
      end

      def check
        log_operation(:eligibility_check, @service_request) do
          @engine.set_facts(build_input_facts)
          eligibility_fact = @engine.evaluate(:is_eligible)
          result = build_result(eligibility_fact)
          log_eligibility_result(result)
          result
        end
      end

      private

      def build_input_facts
        {
          enrollment_number: @patient.tribal_enrollment_number,
          service_area: @patient.service_area,
          reason_for_referral: @service_request.reason_for_referral,
          urgency: @service_request.urgency_symbol,
          coverage_type: @patient.coverage_type,
          service_requested: @service_request.service_requested
        }
      end

      def build_result(eligibility_fact)
        result = EligibilityResult.new(@service_request)
        context = build_message_context

        FACT_TO_CHECK_NAME.each do |fact_name, check_name|
          fact = @engine.evaluate(fact_name)
          result.add_check(check_name, fact_to_check(fact, context))
        end

        result.fact_tree = eligibility_fact
        result
      end

      def build_message_context
        {
          enrollment_number: @patient.tribal_enrollment_number,
          service_area: @patient.service_area,
          reason_for_referral: @service_request.reason_for_referral,
          urgency: @service_request.urgency_symbol,
          coverage_type: @patient.coverage_type,
          service_requested: @service_request.service_requested,
          has_clinical_justification: @engine.evaluate(:has_clinical_justification)&.value
        }
      end

      def fact_to_check(fact, context)
        status = fact.value ? "PASS" : "FAIL"
        message = PrcEligibilityRuleset.message_for(fact.name, fact.value, context)
        { status: status, message: message }
      end

      def log_eligibility_result(result)
        log_info("eligibility_check_result", {
          service_request_ien: @service_request.ien,
          **PhiSanitizer.safe_patient_context(@service_request.patient_dfn),
          eligible: result.eligible?,
          tribal_enrollment: result.check_status(:tribal_enrollment),
          residency: result.check_status(:residency),
          clinical_necessity: result.check_status(:clinical_necessity),
          payor_coordination: result.check_status(:payor_coordination)
        })
      end
    end

    class EligibilityResult
      attr_reader :service_request, :checks
      attr_accessor :fact_tree

      def initialize(service_request)
        @service_request = service_request
        @checks = {}
        @fact_tree = nil
      end

      def add_check(check_name, check_result)
        @checks[check_name.to_sym] = check_result[:message]
        @checks[:"#{check_name}_status"] = check_result[:status]
      end

      def eligible?
        @checks.values.none? { |value| value == "FAIL" }
      end

      def denial_reason
        return nil if eligible?

        failed_checks = @checks.select { |key, value| key.to_s.end_with?("_status") && value == "FAIL" }
        failed_messages = failed_checks.keys.map do |status_key|
          check_name = status_key.to_s.sub("_status", "").to_sym
          @checks[check_name]
        end
        failed_messages.join("; ")
      end

      def check_status(check_name)
        @checks[:"#{check_name}_status"]
      end

      def check_message(check_name)
        @checks[check_name.to_sym]
      end

      def explanation_for_appeals
        return "Patient is eligible for PRC services" if eligible?

        lines = [ "Eligibility denied for the following reasons:" ]
        failed_facts.each do |fact|
          lines << "- #{humanize_fact_name(fact.name)}: #{describe_fact(fact)}"
        end
        lines.join("\n")
      end

      def failed_facts
        return [] unless fact_tree
        collect_failed_facts(fact_tree)
      end

      def all_facts
        return [] unless fact_tree
        fact_tree.all_facts
      end

      private

      def collect_failed_facts(fact, result = [])
        result << fact unless fact.value
        fact.reasons.each { |r| collect_failed_facts(r, result) }
        result.uniq { |f| f.name }
      end

      def humanize_fact_name(name)
        name.to_s.tr("_", " ").capitalize
      end

      def describe_fact(fact)
        case fact.name
        when :is_tribally_enrolled then "Patient does not have valid tribal enrollment"
        when :meets_residency then "Patient is outside the service coverage area"
        when :has_clinical_justification then "Clinical justification is insufficient"
        when :urgency_appropriate then "Urgency level does not match clinical presentation"
        when :has_clinical_necessity then "Clinical necessity requirements not met"
        when :has_payor_coordination then "Payor coordination requirements not met"
        when :is_eligible then "One or more eligibility requirements not met"
        else "Requirement not satisfied"
        end
      end
    end
  end
end
