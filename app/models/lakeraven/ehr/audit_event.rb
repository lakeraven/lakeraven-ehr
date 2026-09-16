# frozen_string_literal: true

module Lakeraven
  module EHR
    # PHI audit log — every authenticated FHIR read produces a row.
    # Immutable once written (ReadOnlyRecord on update).
    # No PHI in the row itself — only identifiers per ADR 0002.
    class AuditEvent < ApplicationRecord
      self.table_name = "lakeraven_ehr_audit_events"

      EVENT_TYPES = {
        "rest" => "RESTful Operation",
        "security" => "Security",
        "application" => "Application",
        "user" => "User Authentication",
        "query" => "Query",
        "import" => "Import",
        "export" => "Export"
      }.freeze

      ACTIONS = {
        "C" => "Create",
        "R" => "Read",
        "U" => "Update",
        "D" => "Delete",
        "E" => "Execute"
      }.freeze

      OUTCOMES = {
        "0" => "Success",
        "4" => "Minor Failure",
        "8" => "Serious Failure",
        "12" => "Major Failure"
      }.freeze

      validates :event_type, presence: true
      validates :action, presence: true, inclusion: { in: ACTIONS.keys }
      validates :outcome, presence: true, inclusion: { in: OUTCOMES.keys }
      validates :entity_type, presence: true
      validate :entity_pair_agreement

      # A Patient is identified by a DFN — digits, nothing else. Anything
      # else filed under Patient is a reference that points nowhere or, worse,
      # at a different patient.
      PATIENT_IDENTIFIER_PATTERN = /\A\d+\z/

      scope :recent, -> { order(created_at: :desc) }

      def readonly?
        persisted?
      end

      # The entity is a REFERENCE — `<entity_type>/<entity_identifier>` — and
      # its halves can be assembled from two different request params by any
      # caller building a row by hand. A dfn filed under a non-Patient type
      # resolves to a DIFFERENT patient's record: a false statement in an
      # accounting-of-disclosures answer, worse than a missing one. The model
      # is the one gate every writer passes through, so the agreement check
      # lives here rather than in each controller path (found on #491; the
      # controller-side rule is `audit_entity_identifier`).
      def entity_pair_agreement
        return if entity_identifier.blank?

        if entity_identifier.to_s.include?("/")
          errors.add(:entity_identifier,
                     "is a reference, not an identifier — pass the bare identifier and let entity_type carry the type")
        end

        if entity_type == "Patient" && !entity_identifier.to_s.match?(PATIENT_IDENTIFIER_PATTERN)
          errors.add(:entity_identifier,
                     "cannot identify a Patient — a Patient entity takes a DFN; a non-DFN here usually means " \
                     "the type and the identifier came from different params")
        end
      end

      # -- Event type helpers --------------------------------------------------

      def event_type_display
        EVENT_TYPES[event_type] || "Unknown"
      end

      # -- Action helpers ------------------------------------------------------

      def create_action? = action == "C"
      def read_action? = action == "R"
      def update_action? = action == "U"
      def delete_action? = action == "D"
      def execute_action? = action == "E"

      def action_display
        ACTIONS[action] || "Unknown"
      end

      # -- Outcome helpers -----------------------------------------------------

      def success? = outcome == "0"
      def minor_failure? = outcome == "4"
      def serious_failure? = outcome == "8"
      def major_failure? = outcome == "12"

      def outcome_display
        OUTCOMES[outcome] || "Unknown"
      end

      # -- Entity helpers ------------------------------------------------------

      def has_entity?
        entity_type.present? && entity_identifier.present?
      end

      # -- FHIR serialization --------------------------------------------------

      def to_fhir
        {
          resourceType: "AuditEvent",
          id: id&.to_s,
          type: build_fhir_type,
          action: action,
          recorded: created_at&.iso8601,
          outcome: outcome,
          outcomeDesc: outcome_desc,
          agent: build_fhir_agents,
          entity: build_fhir_entities
        }.compact
      end

      def self.resource_class
        "AuditEvent"
      end

      def self.from_fhir_attributes(fhir_resource)
        attrs = {}
        attrs[:event_type] = fhir_resource.type&.code if fhir_resource.respond_to?(:type) && fhir_resource.type&.respond_to?(:code)
        attrs[:action] = fhir_resource.action if fhir_resource.respond_to?(:action)
        attrs[:outcome] = fhir_resource.outcome if fhir_resource.respond_to?(:outcome)
        attrs
      end

      private

      def build_fhir_type
        return nil if event_type.blank?

        {
          system: "http://terminology.hl7.org/CodeSystem/audit-event-type",
          code: event_type,
          display: event_type_display
        }
      end

      def build_fhir_agents
        return [] if agent_who_identifier.blank?

        agent = {
          who: {
            reference: "#{agent_who_type || 'Practitioner'}/#{agent_who_identifier}",
            display: agent_name
          }.compact,
          name: agent_name,
          network: agent_network_address.present? ? { address: agent_network_address } : nil
        }.compact

        [ agent ]
      end

      def build_fhir_entities
        return [] unless has_entity?

        [ {
          what: {
            reference: "#{entity_type}/#{entity_identifier}"
          },
          type: entity_type.present? ? { code: entity_type } : nil
        }.compact ]
      end
    end
  end
end
