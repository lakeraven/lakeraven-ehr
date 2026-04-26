# frozen_string_literal: true

module Lakeraven
  module EHR
    # EpcsValidator -- Electronic Prescribing for Controlled Substances
    #
    # ONC 170.315(b)(3) -- Electronic Prescribing (EPCS component)
    #
    # Validates controlled substance prescriptions per DEA EPCS rule (21 CFR 1311).
    # Determines whether a prescription requires:
    #   - Two-factor authentication
    #   - Identity proofing
    #   - DEA number validation
    #
    # DEA Schedules II-V require EPCS; non-controlled substances do not.
    #
    # Ported from rpms_redux EpcsValidator.
    class EpcsValidator
      CONTROLLED_SCHEDULES = %w[II III IV V].freeze

      # Validate a medication order for EPCS requirements
      # @param order [MedicationRequest] The prescription to validate
      # @param dea_schedule [String, nil] DEA schedule (II, III, IV, V, or nil)
      # @param prescriber_dea [String, nil] Prescriber DEA number
      # @return [Hash] Validation result with EPCS requirements
      def self.validate(order, dea_schedule: nil, prescriber_dea: nil)
        new(order, dea_schedule: dea_schedule, prescriber_dea: prescriber_dea).validate
      end

      def initialize(order, dea_schedule:, prescriber_dea:)
        @order = order
        @dea_schedule = dea_schedule
        @prescriber_dea = prescriber_dea
      end

      def validate
        controlled = CONTROLLED_SCHEDULES.include?(@dea_schedule)

        {
          requires_epcs: controlled,
          requires_two_factor: controlled,
          requires_identity_proofing: controlled,
          dea_schedule: @dea_schedule,
          prescriber_dea_valid: controlled ? @prescriber_dea.present? : true,
          medication_code: @order.medication_code,
          medication_display: @order.medication_display
        }
      end
    end
  end
end
