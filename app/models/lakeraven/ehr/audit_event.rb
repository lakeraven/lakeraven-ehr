# frozen_string_literal: true

module Lakeraven
  module EHR
    # PHI audit log — every authenticated FHIR read produces a row.
    # Immutable once written (ReadOnlyRecord on update).
    # No PHI in the row itself — only identifiers per ADR 0002.
    class AuditEvent < ApplicationRecord
      include TamperEvident

      self.table_name = "lakeraven_ehr_audit_events"

      # EXPLICIT, and frozen. Deriving this from `column_names` would mean a
      # later migration adding any column silently invalidated the digest of
      # every row already written — the whole log would read as tampered.
      DIGESTED_ATTRIBUTES = %w[
        event_type action outcome outcome_desc entity_type entity_identifier
        entity_id agent_who_type agent_who_identifier agent_name
        agent_network_address tenant_identifier facility_identifier created_at
      ].freeze

      def self.digested_attributes
        DIGESTED_ATTRIBUTES & column_names
      end

      def self.tampered_events
        tampered_records
      end

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

      scope :recent, -> { order(created_at: :desc) }

      # -- Compliance review ---------------------------------------------------
      #
      # The questions a privacy officer actually asks, as scopes, so the
      # review surface is a composition of them rather than hand-written SQL.

      scope :by_agent, ->(identifier) { where(agent_who_identifier: identifier) }
      scope :about_entity, ->(identifier) { where(entity_identifier: identifier) }
      scope :of_type, ->(entity_type) { where(entity_type: entity_type) }
      scope :with_action, ->(value) { where(action: value) }
      scope :with_outcome, ->(value) { where(outcome: value) }
      scope :refusals, -> { where.not(outcome: "0") }
      scope :unattributed, -> { where(agent_who_type: "Unknown").or(where(agent_who_identifier: nil)) }
      scope :occurring_after, ->(time) { where(created_at: time..) }
      scope :occurring_before, ->(time) { where(created_at: ..time) }
      scope :for_tenant, ->(identifier) { where(tenant_identifier: identifier) }

      # One filter hash in, one relation out. Blank values are IGNORED rather
      # than matched as NULL, so a half-filled review form widens the search
      # instead of silently returning nothing.
      FILTERS = {
        agent: :by_agent, entity: :about_entity, entity_type: :of_type,
        action: :with_action, outcome: :with_outcome, tenant: :for_tenant,
        from: :occurring_after, to: :occurring_before
      }.freeze

      def self.review(filters = {})
        FILTERS.reduce(all) do |relation, (key, scope_name)|
          value = filters[key].presence || filters[key.to_s].presence
          value ? relation.public_send(scope_name, value) : relation
        end.recent
      end

      def readonly?
        persisted?
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
