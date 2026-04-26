# frozen_string_literal: true

module Lakeraven
  module EHR
    module CpoeAuditor
      module_function

      def record_order_created(order, provider_duz:)
        create_event(
          description: "#{order_category(order)} order created",
          action: "C",
          order: order,
          provider_duz: provider_duz
        )
      end

      def record_order_signed(order, provider_duz:)
        create_event(
          description: "#{order_category(order)} order signed. Content hash: #{content_hash(order)}",
          action: "E",
          order: order,
          provider_duz: provider_duz
        )
      end

      def record_order_cancelled(order, provider_duz:, reason: nil)
        desc = "#{order_category(order)} order cancelled"
        desc += ". Reason: #{reason}" if reason.present?
        create_event(
          description: desc,
          action: "D",
          order: order,
          provider_duz: provider_duz
        )
      end

      def record_prescription_transmitted(order, provider_duz:, transmission_id:)
        AuditEvent.create!(
          event_type: "application",
          action: "E",
          outcome: "0",
          agent_who_type: "Practitioner",
          agent_who_identifier: provider_duz.to_s,
          entity_type: "MedicationRequest",
          entity_identifier: order_id(order),
          entity_id: order_id(order),
          outcome_desc: "Transmission ID: #{transmission_id}"
        )
      end

      def record_prescription_cancelled(transmission_id:, provider_duz:, reason: nil, order: nil)
        desc = [ "Transmission ID: #{transmission_id}" ]
        desc << "Reason: #{reason}" if reason.present?

        entity_ident = order ? order_id(order) : transmission_id

        AuditEvent.create!(
          event_type: "application",
          action: "D",
          outcome: "0",
          agent_who_type: "Practitioner",
          agent_who_identifier: provider_duz.to_s,
          entity_type: "MedicationRequest",
          entity_identifier: entity_ident,
          entity_id: entity_ident,
          outcome_desc: desc.join("; ")
        )
      end

      def record_event(type:, subtype:, action:, provider_duz:, description: nil)
        AuditEvent.create!(
          event_type: type,
          action: action,
          outcome: "0",
          agent_who_type: "Practitioner",
          agent_who_identifier: provider_duz.to_s,
          entity_type: "CpoeOrder",
          outcome_desc: "#{subtype}: #{description}"
        )
      end

      # private helpers
      def create_event(description:, action:, order:, provider_duz:)
        AuditEvent.create!(
          event_type: "application",
          action: action,
          outcome: "0",
          agent_who_type: "Practitioner",
          agent_who_identifier: provider_duz.to_s,
          entity_type: order_entity_type(order),
          entity_identifier: order_id(order),
          entity_id: order_id(order),
          outcome_desc: description
        )
      end

      def order_category(order)
        if order.is_a?(MedicationRequest)
          "medication"
        elsif order.respond_to?(:category)
          order.category || "unknown"
        else
          "unknown"
        end
      end

      def order_entity_type(order)
        order.is_a?(MedicationRequest) ? "MedicationRequest" : "ServiceRequest"
      end

      def order_id(order)
        order.respond_to?(:ien) ? order.ien.to_s : order.respond_to?(:id) ? order.id.to_s : nil
      end

      def content_hash(order)
        order.respond_to?(:signed_content_hash) ? order.signed_content_hash : nil
      end
    end
  end
end
