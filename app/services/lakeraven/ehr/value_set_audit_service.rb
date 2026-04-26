# frozen_string_literal: true

module Lakeraven
  module EHR
    # ValueSet Audit Service
    #
    # Audit trail for terminology and ValueSet operations.
    # Uses an in-memory ProvenanceStore to track access, expansion, and
    # modifications to ValueSets for compliance and security auditing.
    #
    # Ported from rpms_redux ValueSetAuditService.
    class ValueSetAuditService
      # Activity codes for ValueSet operations
      ACTIVITY_ACCESS = "EXECUTE"
      ACTIVITY_EXPAND = "EXECUTE"
      ACTIVITY_CREATE = "CREATE"
      ACTIVITY_UPDATE = "UPDATE"
      ACTIVITY_DELETE = "DELETE"

      # Reason codes for ValueSet operations
      REASON_ACCESS     = "HMARKT"
      REASON_VALIDATION = "HACCRD"
      REASON_EXPANSION  = "HRESCH"
      REASON_ADMIN      = "HSYSADMIN"

      # Lightweight provenance record for audit trail
      class AuditProvenance
        attr_accessor :target_type, :target_id, :recorded, :activity,
                      :agent_who_id, :agent_type, :reason_code, :reason_display,
                      :chain_of_custody, :entity_what_type, :entity_what_id, :entity_role

        def initialize(attrs = {})
          attrs.each { |k, v| public_send(:"#{k}=", v) }
          @recorded ||= DateTime.current
        end
      end

      attr_reader :store

      def initialize(store: ProvenanceStore.new)
        @store = store
      end

      def record_access(valueset_id, agent_id:, agent_type: "performer", reason: nil)
        create_provenance(
          target_type: "ValueSet",
          target_id: valueset_id,
          activity: ACTIVITY_ACCESS,
          agent_who_id: agent_id,
          agent_type: agent_type,
          reason_code: reason || REASON_ACCESS,
          reason_display: "ValueSet access"
        )
      end

      def record_expansion(valueset_id, agent_id:, code_count: nil, cached: false)
        provenance = create_provenance(
          target_type: "ValueSet",
          target_id: valueset_id,
          activity: ACTIVITY_EXPAND,
          agent_who_id: agent_id,
          agent_type: "performer",
          reason_code: REASON_EXPANSION,
          reason_display: "ValueSet expansion"
        )

        metadata = { code_count: code_count, cached: cached }
        provenance.chain_of_custody = metadata.to_json

        provenance
      end

      def record_validation(valueset_id, code:, agent_id:, result:)
        provenance = create_provenance(
          target_type: "ValueSet",
          target_id: valueset_id,
          activity: ACTIVITY_ACCESS,
          agent_who_id: agent_id,
          agent_type: "performer",
          reason_code: REASON_VALIDATION,
          reason_display: "Code validation"
        )

        metadata = { code: code, result: result }
        provenance.chain_of_custody = metadata.to_json

        provenance
      end

      def record_create(valueset_id, agent_id:, source: nil)
        provenance = create_provenance(
          target_type: "ValueSet",
          target_id: valueset_id,
          activity: ACTIVITY_CREATE,
          agent_who_id: agent_id,
          agent_type: "author",
          reason_code: REASON_ADMIN,
          reason_display: "ValueSet creation"
        )

        if source.present?
          provenance.entity_what_type = "DocumentReference"
          provenance.entity_what_id = source
          provenance.entity_role = "source"
        end

        provenance
      end

      def record_update(valueset_id, agent_id:, changes: nil)
        provenance = create_provenance(
          target_type: "ValueSet",
          target_id: valueset_id,
          activity: ACTIVITY_UPDATE,
          agent_who_id: agent_id,
          agent_type: "author",
          reason_code: REASON_ADMIN,
          reason_display: "ValueSet update"
        )

        if changes.present?
          provenance.chain_of_custody = changes.to_json
        end

        provenance
      end

      def record_delete(valueset_id, agent_id:, reason: nil)
        create_provenance(
          target_type: "ValueSet",
          target_id: valueset_id,
          activity: ACTIVITY_DELETE,
          agent_who_id: agent_id,
          agent_type: "author",
          reason_code: REASON_ADMIN,
          reason_display: reason || "ValueSet deletion"
        )
      end

      def history(valueset_id, limit: 100, activity: nil)
        records = @store.for_target("ValueSet", valueset_id)
        records = records.select { |p| p.activity == activity } if activity.present?
        records.sort_by { |p| p.recorded }.reverse.first(limit)
      end

      def agent_history(agent_id, limit: 50)
        @store.by_agent(agent_id)
              .select { |p| p.target_type == "ValueSet" }
              .sort_by { |p| p.recorded }
              .reverse
              .first(limit)
      end

      def usage_stats(valueset_id, since: nil)
        scope = @store.for_target("ValueSet", valueset_id)
        scope = scope.select { |p| p.recorded >= since } if since.present?

        {
          total_operations: scope.count,
          access_count: scope.count { |p| p.reason_code == REASON_ACCESS },
          expansion_count: scope.count { |p| p.reason_code == REASON_EXPANSION },
          validation_count: scope.count { |p| p.reason_code == REASON_VALIDATION },
          unique_agents: scope.map(&:agent_who_id).uniq.count,
          last_accessed: scope.map(&:recorded).max
        }
      end

      private

      def create_provenance(attrs)
        provenance = AuditProvenance.new(attrs)
        @store.add(provenance)
        provenance
      end
    end
  end
end
