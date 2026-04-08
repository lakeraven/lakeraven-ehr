# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 AuditEvent — persistent record of PHI access.
    #
    # Every PHI-touching request through the engine's FHIR controllers
    # produces one of these, via the AuditableClinicalAccess controller
    # concern running as an after_action. The rows are tenant-scoped
    # and carry only opaque identifiers per ADR 0002 — no names, no
    # DOBs, no clinical content, just pointers and codes.
    #
    # Immutability: once a row is persisted, update and destroy both
    # raise. HIPAA § 164.312(b) requires the audit trail to be
    # tamper-evident and the simplest way to satisfy that is to make
    # it uneditable at the ORM layer.
    #
    # Reference: https://hl7.org/fhir/R4/auditevent.html
    class AuditEvent < ApplicationRecord
      # FHIR AuditEvent.type code system
      # https://hl7.org/fhir/R4/valueset-audit-event-type.html
      EVENT_TYPES = {
        "rest"        => "RESTful Operation",
        "security"    => "Security",
        "application" => "Application",
        "user"        => "User Authentication",
        "query"       => "Query",
        "import"      => "Import",
        "export"      => "Export"
      }.freeze

      # FHIR AuditEvent.action CRUDE codes
      ACTIONS = {
        "C" => "Create",
        "R" => "Read",
        "U" => "Update",
        "D" => "Delete",
        "E" => "Execute"
      }.freeze

      # FHIR AuditEvent.outcome codes
      OUTCOMES = {
        "0"  => "Success",
        "4"  => "Minor Failure",
        "8"  => "Serious Failure",
        "12" => "Major Failure"
      }.freeze

      validates :event_type, presence: true, inclusion: { in: EVENT_TYPES.keys }
      validates :action, presence: true, inclusion: { in: ACTIONS.keys }
      validates :outcome, presence: true, inclusion: { in: OUTCOMES.keys }
      validates :recorded, presence: true
      validates :tenant_identifier, presence: true
      validates :agent_who_type, presence: true
      validates :agent_who_identifier, presence: true

      before_validation :set_recorded_timestamp, on: :create

      scope :for_tenant, ->(tenant_identifier) { where(tenant_identifier: tenant_identifier) }
      scope :for_entity, ->(type, identifier) { where(entity_type: type, entity_identifier: identifier) }
      scope :for_agent, ->(type, identifier) { where(agent_who_type: type, agent_who_identifier: identifier) }
      scope :by_action, ->(action) { where(action: action) }
      scope :successful, -> { where(outcome: "0") }
      scope :failed, -> { where.not(outcome: "0") }
      scope :recent, -> { order(recorded: :desc) }

      # -- immutability --------------------------------------------------------

      # Once persisted, an audit row is immutable. The CurrentAttributes
      # lookup below preserves the tenant context for new rows while
      # rejecting every ActiveRecord write path that would mutate or
      # delete a persisted one.
      def readonly?
        persisted?
      end

      def destroy
        raise ActiveRecord::ReadOnlyRecord,
          "Lakeraven::EHR::AuditEvent is immutable (HIPAA § 164.312(b)); " \
          "destroy is not permitted"
      end

      def delete
        raise ActiveRecord::ReadOnlyRecord,
          "Lakeraven::EHR::AuditEvent is immutable (HIPAA § 164.312(b)); " \
          "delete is not permitted"
      end

      def success?
        outcome == "0"
      end

      def failure?
        outcome != "0"
      end

      private

      def set_recorded_timestamp
        self.recorded ||= Time.current
      end
    end
  end
end
