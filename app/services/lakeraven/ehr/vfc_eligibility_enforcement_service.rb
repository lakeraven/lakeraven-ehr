# frozen_string_literal: true

# VfcEligibilityEnforcementService -- enforces VFC/VFA lot eligibility rules
#
# Fail-closed: if eligibility or lot data is unavailable, the check fails.
# Creates AuditEvent for every enforcement decision.
#
# VFC eligibility codes (BIELIG.m):
#   V01 = Not VFC eligible
#   V02-V07 = Various VFC-eligible categories (Medicaid, uninsured, AI/AN, etc.)

module Lakeraven
  module EHR
    class VfcEligibilityEnforcementService
      VFC_ELIGIBLE_CODES = %w[V02 V03 V04 V05 V06 V07].freeze

      class << self
        # Validate that a patient is eligible to receive vaccine from the given lot.
        #
        # @param patient_dfn [String]
        # @param lot_ien [String]
        # @return [Hash] { success: Boolean, reason: String? }
        def validate(patient_dfn:, lot_ien:)
          lot_data = begin
            find_lot(lot_ien)
          rescue => e
            result = { success: false, reason: "Vaccine lot lookup failed: #{e.class}" }
            record_audit(patient_dfn, lot_ien, result)
            return result
          end

          unless lot_data
            result = { success: false, reason: "Vaccine lot not found" }
            record_audit(patient_dfn, lot_ien, result)
            return result
          end

          # Non-VFC lots are available to all patients
          unless lot_data[:funding_source] == "VFC"
            result = { success: true, reason: nil }
            record_audit(patient_dfn, lot_ien, result)
            return result
          end

          # VFC lot -- check patient eligibility
          eligibility = begin
            patient_eligibility(patient_dfn)
          rescue => e
            result = { success: false, reason: "Eligibility lookup failed: #{e.class}" }
            record_audit(patient_dfn, lot_ien, result)
            return result
          end

          unless eligibility[:code].present?
            result = { success: false, reason: "Patient eligibility unknown -- cannot confirm VFC eligibility" }
            record_audit(patient_dfn, lot_ien, result)
            return result
          end

          result = if VFC_ELIGIBLE_CODES.include?(eligibility[:code])
            { success: true, reason: nil }
          else
            { success: false,
              reason: "Patient VFC eligibility code #{eligibility[:code]} does not permit VFC vaccine" }
          end

          record_audit(patient_dfn, lot_ien, result)
          result
        end

        # Return lots eligible for a patient, filtered by vaccine code.
        #
        # @param patient_dfn [String]
        # @param vaccine_code [String] CVX code
        # @return [Array<Hash>]
        def eligible_lots_for_patient(patient_dfn:, vaccine_code:)
          all_lots = list_lots
          return [] unless all_lots.is_a?(Array)

          eligibility = begin
            patient_eligibility(patient_dfn)
          rescue
            { code: nil, label: nil }
          end
          patient_vfc_eligible = VFC_ELIGIBLE_CODES.include?(eligibility[:code])

          all_lots
            .select { |lot| lot[:vaccine_code] == vaccine_code }
            .reject { |lot| lot[:funding_source] == "VFC" && !patient_vfc_eligible }
        end

        # --- Seams for DI (override in tests via define_singleton_method) ---

        def find_lot(lot_ien)
          EligibilityGateway.find_lot(lot_ien)
        end

        def patient_eligibility(dfn)
          EligibilityGateway.patient_eligibility(dfn)
        end

        def list_lots
          EligibilityGateway.list_lots
        end

        private

        def record_audit(patient_dfn, lot_ien, result)
          AuditEvent.create(
            event_type: "application",
            action: "E",
            outcome: result[:success] ? "0" : "8",
            outcome_desc: result[:reason],
            agent_who_identifier: "VfcEligibilityEnforcementService",
            agent_who_type: "System",
            entity_type: "Immunization",
            entity_id: lot_ien
          )
        rescue => e
          Rails.logger.error("VfcEligibilityEnforcementService audit failed: #{e.message}")
        end
      end
    end
  end
end
