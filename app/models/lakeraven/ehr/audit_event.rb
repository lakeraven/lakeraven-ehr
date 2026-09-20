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
      # Guarded by a test: adding a column to the digest input is a DECISION
      # (it re-scopes what "unaltered" means), never drift.
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

      # Used by AuditRetention; time-inclusive upper bound.
      scope :occurring_before, ->(time) { where(created_at: ..time) }

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
      validate :entity_identifier_shape

      # A Patient is identified by a DFN — digits, nothing else. Anything
      # else filed under Patient is a reference that points nowhere or, worse,
      # at a different patient.
      PATIENT_IDENTIFIER_PATTERN = /\A\d+\z/

      scope :recent, -> { order(created_at: :desc) }

      # A row that SURVIVES any transaction open on the calling thread (F3
      # on the #512 gate). For records of things that already irreversibly
      # happened — an RPC executed against RPMS, an action that raised inside
      # a caller-owned transaction: rolling the caller back cannot undo the
      # remote effect, so it must not erase the record of it either.
      #
      # `requires_new: true` is NOT enough here: inside an open transaction
      # it is a savepoint, and releasing a savepoint into a parent that later
      # rolls back discards it. Surviving requires a write the caller's
      # connection cannot take down — a fresh thread leasing its own pooled
      # connection, joined synchronously so a failure still surfaces to the
      # caller (fail closed). Costs one extra pool connection for the
      # duration of the insert.
      #
      # Attribute resolution must happen on the CALLING thread before this is
      # invoked (AuditContext is thread-local): pass fully-resolved values.
      #
      # Under the TRANSACTIONAL-TEST harness the pool pins one thread-locked
      # connection and hands it to every checkout from any thread — a
      # detached thread deadlocks against the test thread by design, and its
      # write would join the test transaction anyway. So a pinned connection
      # writes inline; the survival property is proven by dedicated tests
      # that opt out of the transactional wrapper (production never pins).
      def self.create_detached!(attributes)
        conn = connection
        return create!(**attributes) unless conn.transaction_open?
        return create!(**attributes) if conn.respond_to?(:pinned) && conn.pinned

        Thread.new do
          Thread.current.report_on_exception = false
          connection_pool.with_connection { create!(**attributes) }
        end.value
      end

      def readonly?
        persisted?
      end

      # A SHAPE check, and honestly no more than that (round-2 gate on #512):
      # it refuses an identifier that is itself a reference, and a non-DFN
      # filed under Patient. It CANNOT establish type/identifier AGREEMENT —
      # `entity_type: "QuestionnaireResponse", entity_identifier: "12"` (a
      # DFN) passes, because a bare numeric is also a legitimate IEN for most
      # types, and rejecting it would refuse true rows. The protection
      # against a mismatched pair is the CONTROLLER feeder
      # (`audit_entity_identifier`, per #491): only a param that names a
      # record of the audited type reaches the row. Do not cite this
      # validation as agreement enforcement.
      def entity_identifier_shape
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
