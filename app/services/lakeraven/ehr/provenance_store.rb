# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory provenance store for ValueSetAuditService and FHIR _revinclude.
    # Replaces ActiveRecord Provenance scopes with plain Ruby collections.
    class ProvenanceStore
      def initialize
        @records = []
      end

      def self.instance
        @instance ||= new
      end

      def self.reset_instance!
        @instance = new
      end

      def add(provenance)
        @records << provenance
      end

      def clear!
        @records.clear
      end

      def all
        @records.dup
      end

      def for_target(target_type, target_id)
        @records.select { |p| p.target_type == target_type && p.target_id == target_id }
      end

      def by_agent(agent_id)
        @records.select { |p| p.agent_who_id == agent_id }
      end

      def count
        @records.count
      end
    end
  end
end
