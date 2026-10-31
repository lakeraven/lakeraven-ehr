# frozen_string_literal: true

module Lakeraven
  module EHR
    # CoverageSummaryService - Summarizes patient coverage for PRC determination.
    # Ported from the predecessor app CoverageSummaryService.
    class CoverageSummaryService
      PAYER_PRIORITY = {
        "workers_comp" => 1,
        "auto_insurance" => 1,
        "private_insurance" => 2,
        "medicare_a" => 3,
        "medicare_b" => 3,
        "medicare_d" => 3,
        "va_benefits" => 4,
        "state_program" => 5,
        "tribal_program" => 5,
        "medicaid" => 6,
        "ihs_prc" => 99
      }.freeze

      # Residual payer on a PRC referral. Not a Coverage record.
      PRC_PAYER = "IHS Purchased/Referred Care"

      Summary = Struct.new(
        :coverages,
        :active_coverages,
        :expired_coverages,
        :exhausted_coverages,
        :not_enrolled,
        :payer_hierarchy,
        :primary_payer,
        :secondary_payers,
        :prc_eligible,
        :requires_coordination,
        :authorization_reason,
        keyword_init: true
      )

      # prc_eligible is EligibilityService's answer when the eligibility summary
      # already has one. Nil means the caller did not supply that answer.
      def initialize(coverages, service_request: nil, prc_eligible: nil)
        @coverages = Array(coverages)
        @service_request = service_request
        @patient_prc_eligible = prc_eligible
      end

      def summarize
        active = @coverages.select(&:active?)
        expired = @coverages.select(&:expired?)
        exhausted = @coverages.select { |c| c.status == "exhausted" }
        not_enrolled = @coverages.select { |c| c.status == "not_enrolled" }

        hierarchy = determine_payer_hierarchy(active)
        primary = hierarchy.first
        secondary = hierarchy[1..]

        prc_result = determine_prc_eligibility(active, exhausted)

        Summary.new(
          coverages: @coverages,
          active_coverages: active,
          expired_coverages: expired,
          exhausted_coverages: exhausted,
          not_enrolled: not_enrolled,
          payer_hierarchy: hierarchy,
          primary_payer: primary,
          secondary_payers: secondary,
          prc_eligible: summary_prc_eligible(prc_result),
          requires_coordination: active.any?,
          authorization_reason: prc_result[:reason]
        )
      end

      def determine_payer_hierarchy(active_coverages = nil)
        coverages = active_coverages || @coverages.select(&:active?)
        append_prc_last(ranked_payor_names(coverages))
      end

      def primary_payer
        hierarchy = determine_payer_hierarchy
        hierarchy.first
      end

      def secondary_payers
        hierarchy = determine_payer_hierarchy
        hierarchy[1..] || []
      end

      def prc_eligible?
        result = determine_prc_eligibility
        result[:eligible]
      end

      def requires_coordination?
        @coverages.any?(&:active?)
      end

      private

      def ranked_payor_names(coverages)
        coverages.sort_by { |coverage| payer_sort_key(coverage) }.map(&:payer_hierarchy_name).uniq
      end

      def payer_sort_key(coverage)
        [ PAYER_PRIORITY[coverage.coverage_type] || 50, coverage.payer_hierarchy_name || "" ]
      end

      # On a referral, Summary#prc_eligible matches the eligibility gate:
      # true only when the caller passed true. Without a referral, the
      # coverage-derived answer stands.
      def summary_prc_eligible(prc_result)
        return @patient_prc_eligible == true if @service_request.present?

        prc_result[:eligible]
      end

      # PRC is appended once, after every active payer, only on a referral
      # whose caller passed prc_eligible: true. Nil and false fail closed.
      # With no active coverage, that still makes PRC the primary payer.
      def append_prc_last(hierarchy)
        return hierarchy unless prc_last_resort?

        hierarchy.reject { |payer| payer == PRC_PAYER } + [ PRC_PAYER ]
      end

      def prc_last_resort?
        @service_request.present? && @patient_prc_eligible == true
      end

      def determine_prc_eligibility(active = nil, exhausted = nil)
        active ||= @coverages.select(&:active?)
        exhausted ||= @coverages.select { |c| c.status == "exhausted" }

        if active.any?
          return {
            eligible: true,
            reason: "requires coordination of benefits with active coverage"
          }
        end

        if exhausted.any? || @coverages.all? { |c| %w[exhausted not_enrolled denied].include?(c.status) }
          return {
            eligible: true,
            reason: "alternate resources exhausted"
          }
        end

        {
          eligible: true,
          reason: "no other coverage identified"
        }
      end
    end
  end
end
