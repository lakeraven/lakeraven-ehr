# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # Serializes a Lakeraven::EHR::AuditEvent record into a FHIR R4
      # AuditEvent resource as a Ruby Hash.
      #
      # Reference: https://hl7.org/fhir/R4/auditevent.html
      class AuditEventSerializer
        def self.call(record)
          new(record).to_h
        end

        def initialize(record)
          @record = record
        end

        def to_h
          {
            resourceType: "AuditEvent",
            id: @record.audit_event_identifier,
            type: build_type,
            action: @record.action,
            recorded: @record.recorded&.iso8601,
            outcome: @record.outcome,
            outcomeDesc: AuditEvent::OUTCOMES[@record.outcome],
            agent: [ build_agent ],
            source: build_source,
            entity: build_entities
          }.compact
        end

        private

        def build_type
          {
            system: "http://terminology.hl7.org/CodeSystem/audit-event-type",
            code: @record.event_type,
            display: AuditEvent::EVENT_TYPES[@record.event_type]
          }
        end

        def build_agent
          agent = {
            type: {
              coding: [ {
                system: "http://terminology.hl7.org/CodeSystem/extra-security-role-type",
                code: @record.agent_who_type.downcase
              } ]
            },
            who: {
              identifier: {
                value: @record.agent_who_identifier
              }
            },
            requestor: true
          }
          if @record.agent_network_address
            agent[:network] = { address: @record.agent_network_address, type: "2" }
          end
          agent
        end

        def build_source
          {
            observer: {
              display: @record.source_observer || "lakeraven-ehr"
            }
          }
        end

        def build_entities
          return nil if @record.entity_type.nil? || @record.entity_identifier.nil?

          [ {
            what: {
              identifier: {
                value: @record.entity_identifier
              }
            },
            type: {
              system: "http://terminology.hl7.org/CodeSystem/audit-entity-type",
              code: @record.entity_type
            }
          } ]
        end
      end
    end
  end
end
