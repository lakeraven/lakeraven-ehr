# frozen_string_literal: true

module Lakeraven
  module EHR
    # CpoeService - Computerized Provider Order Entry
    # ONC 170.315(a)(1-3) - CPOE Medications, Laboratory, Diagnostic Imaging
    class CpoeService
      class << self
        def create_medication_order(patient_dfn:, provider_duz:, medication:, **options)
          errors = []
          errors << "Patient is required" if patient_dfn.blank?
          errors << "Provider is required" if provider_duz.blank?
          errors << "Medication is required" if medication.blank?
          return OrderResult.failure(errors) if errors.any?

          order = MedicationRequest.new(
            ien: generate_order_id,
            patient_dfn: patient_dfn.to_s,
            medication_display: medication,
            medication_code: options[:rxnorm_code],
            status: "draft",
            intent: "plan",
            dosage_instruction: options[:dosage],
            route: options[:route],
            frequency: options[:frequency],
            dispense_quantity: options[:quantity],
            refills: options[:refills],
            days_supply: options[:days_supply],
            requester_duz: provider_duz.to_s,
            requester_name: options[:provider_name],
            authored_on: Time.current
          )

          interaction_result = DrugInteractionService.new.check(
            active_medications: MedicationRequest.for_patient(patient_dfn),
            proposed_medication: order,
            allergies: AllergyIntolerance.for_patient(patient_dfn)
          )

          CpoeAuditor.record_order_created(order, provider_duz: provider_duz)
          OrderResult.success(order, interaction_result: interaction_result)
        end

        def create_lab_order(patient_dfn:, provider_duz:, test_name:, test_code: nil, priority: "routine", clinical_reason: nil)
          errors = []
          errors << "Patient is required" if patient_dfn.blank?
          errors << "Provider is required" if provider_duz.blank?
          errors << "Test name is required" if test_name.blank?
          return OrderResult.failure(errors) if errors.any?

          order = CpoeOrder.new(
            id: generate_order_id,
            patient_dfn: patient_dfn.to_s,
            requester_duz: provider_duz.to_s,
            status: "draft",
            intent: "plan",
            category: "laboratory",
            priority: priority || "routine",
            code: test_code,
            code_display: test_name,
            clinical_reason: clinical_reason,
            authored_on: Time.current
          )

          CpoeAuditor.record_order_created(order, provider_duz: provider_duz)
          OrderResult.success(order)
        end

        def create_imaging_order(patient_dfn:, provider_duz:, study_type:, body_site: nil, laterality: nil, clinical_reason: nil, priority: "routine")
          errors = []
          errors << "Patient is required" if patient_dfn.blank?
          errors << "Provider is required" if provider_duz.blank?
          errors << "Study type is required" if study_type.blank?
          return OrderResult.failure(errors) if errors.any?

          order = CpoeOrder.new(
            id: generate_order_id,
            patient_dfn: patient_dfn.to_s,
            requester_duz: provider_duz.to_s,
            status: "draft",
            intent: "plan",
            category: "imaging",
            priority: priority || "routine",
            code_display: study_type,
            body_site: body_site,
            laterality: laterality,
            clinical_reason: clinical_reason,
            authored_on: Time.current
          )

          CpoeAuditor.record_order_created(order, provider_duz: provider_duz)
          OrderResult.success(order)
        end

        def sign_order(order, provider_duz:, transmit: true)
          if order.is_a?(MedicationRequest)
            order.status = "active"
            order.intent = "order"
          else
            order.sign!(provider_duz: provider_duz)
          end

          CpoeAuditor.record_order_signed(order, provider_duz: provider_duz)

          erx_result = nil
          if transmit && order.is_a?(MedicationRequest)
            erx_result = EprescribingService.new.transmit(order, provider_duz: provider_duz)
          end

          OrderResult.success(order, erx_result: erx_result)
        end

        def cancel_order(order, provider_duz: nil, reason: nil)
          if order.is_a?(MedicationRequest)
            order.status = "cancelled"
          else
            order.cancel!
          end

          provider = provider_duz.presence || order.requester_duz.presence
          return OrderResult.failure("Provider is required to cancel order") if provider.blank?
          CpoeAuditor.record_order_cancelled(order, provider_duz: provider, reason: reason)
          OrderResult.success(order)
        end

        private

        def generate_order_id
          "cpoe-#{SecureRandom.hex(8)}"
        end
      end
    end

    class OrderResult
      attr_reader :order, :errors, :interaction_result, :erx_result

      def initialize(order:, errors:, interaction_result: nil, erx_result: nil)
        @order = order
        @errors = errors
        @interaction_result = interaction_result
        @erx_result = erx_result
      end

      def self.success(order, interaction_result: nil, erx_result: nil)
        new(order: order, errors: [], interaction_result: interaction_result, erx_result: erx_result)
      end

      def self.failure(errors)
        new(order: nil, errors: Array(errors), interaction_result: nil)
      end

      def success?
        errors.empty?
      end

      def has_interaction_alerts?
        interaction_result&.interactions&.any? || false
      end

      def interaction_alerts
        interaction_result&.interactions || []
      end
    end
  end
end
