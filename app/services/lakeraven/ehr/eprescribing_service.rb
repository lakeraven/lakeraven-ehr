# frozen_string_literal: true

module Lakeraven
  module EHR
    # EprescribingService - Electronic prescription transmission.
    # ONC 170.315(b)(3) - Electronic Prescribing
    class EprescribingService
      class PrescriptionNotSignedError < StandardError; end
      class PrescriptionNotActiveError < StandardError; end

      def initialize(adapter: nil)
        @adapter = adapter || Eprescribing::EprescribingAdapterFactory.build
      end

      def transmit(order, provider_duz:)
        refusal = MatMoudMedication.refusal_for_order(order.medication_display, order.dosage_instruction)
        return Eprescribing::TransmissionResult.failure(refusal) if refusal

        validate_for_transmission!(order)

        result = @adapter.send_prescription(order)

        if result.success?
          CpoeAuditor.record_prescription_transmitted(order, provider_duz: provider_duz, transmission_id: result.transmission_id)
        end

        result
      end

      def check_status(transmission_id)
        @adapter.check_status(transmission_id)
      end

      def cancel(transmission_id, provider_duz:, reason: nil, order: nil)
        result = @adapter.cancel_prescription(transmission_id, reason: reason)

        if result.success?
          CpoeAuditor.record_prescription_cancelled(
            transmission_id: transmission_id,
            provider_duz: provider_duz,
            reason: reason,
            order: order
          )
        end

        result
      end

      def request_refill(transmission_id, pharmacy_ncpdpid:)
        @adapter.request_refill(transmission_id, pharmacy_ncpdpid: pharmacy_ncpdpid)
      end

      def approve_refill(refill_id, provider_duz:)
        result = @adapter.approve_refill(refill_id)

        if result.success?
          CpoeAuditor.record_event(
            type: "e-prescribing",
            subtype: "refill_approved",
            action: "E",
            provider_duz: provider_duz,
            description: "Refill approved: #{refill_id}"
          )
        end

        result
      end

      def deny_refill(refill_id, provider_duz:, reason: nil)
        @adapter.deny_refill(refill_id, reason: reason)
      end

      def request_change(transmission_id, pharmacy_ncpdpid:, new_medication:)
        refusal = MatMoudMedication.refusal_for(change_medication_text(new_medication))
        return Eprescribing::TransmissionResult.failure(refusal) if refusal

        @adapter.request_change(transmission_id, pharmacy_ncpdpid: pharmacy_ncpdpid, new_medication: new_medication)
      end

      # Refused for every change id (#904): the medication a pharmacy change
      # proposes cannot be read from a change id here, so it cannot be shown
      # not to be MAT/MOUD. The adapter is never called, and the error names the
      # change that was not approved rather than claiming an order was refused.
      def approve_change(change_id, provider_duz:)
        Eprescribing::TransmissionResult.failure(MatMoudMedication::CHANGE_APPROVAL_REFUSAL)
      end

      def deny_change(change_id, provider_duz:, reason: nil)
        @adapter.deny_change(change_id, reason: reason)
      end

      private

      # The adapter is given either the medication text or a { code:, display: }
      # hash; NcpdpScriptGenerator sends new_medication[:display] as the
      # DrugDescription, so that is the text read. Any other shape yields no
      # text and is refused.
      def change_medication_text(new_medication)
        new_medication.is_a?(Hash) ? new_medication[:display] : new_medication
      end

      def validate_for_transmission!(order)
        raise PrescriptionNotActiveError, "Order status must be active for transmission" if order.status == "cancelled"
        raise PrescriptionNotSignedError, "Order must be signed before transmission" unless order.status == "active" && order.intent == "order"
      end
    end
  end
end
