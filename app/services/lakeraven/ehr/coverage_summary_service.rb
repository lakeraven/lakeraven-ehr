# frozen_string_literal: true

module Lakeraven
  module EHR
    # CoverageSummaryService - Summarizes patient coverage for PRC determination.
    # Ported from rpms_redux CoverageSummaryService.
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

      def initialize(coverages)
        @coverages = Array(coverages)
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
          prc_eligible: prc_result[:eligible],
          requires_coordination: active.any?,
          authorization_reason: prc_result[:reason]
        )
      end

      def determine_payer_hierarchy(active_coverages = nil)
        coverages = active_coverages || @coverages.select(&:active?)

        coverages
          .sort_by { |c| [ PAYER_PRIORITY[c.coverage_type] || 50, c.payor_display || "" ] }
          .map(&:payor_display)
          .uniq
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
