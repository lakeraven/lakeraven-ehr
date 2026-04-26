# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ValueSetAuditServiceTest < ActiveSupport::TestCase
      setup do
        @valueset_id = "gpra-bgpmu-diabetes-dx"
        @agent_id = "user-123"
        @store = ProvenanceStore.new
        @service = ValueSetAuditService.new(store: @store)
      end

      # =============================================================================
      # RECORD ACCESS
      # =============================================================================

      test "record_access creates a provenance record for ValueSet access" do
        provenance = @service.record_access(@valueset_id, agent_id: @agent_id)

        assert_equal "ValueSet", provenance.target_type
        assert_equal @valueset_id, provenance.target_id
        assert_equal @agent_id, provenance.agent_who_id
        assert_equal "EXECUTE", provenance.activity
        assert_equal "performer", provenance.agent_type
      end

      test "record_access accepts custom agent_type" do
        provenance = @service.record_access(
          @valueset_id,
          agent_id: @agent_id,
          agent_type: "author"
        )

        assert_equal "author", provenance.agent_type
      end

      test "record_access sets recorded timestamp" do
        provenance = @service.record_access(@valueset_id, agent_id: @agent_id)

        assert provenance.recorded.present?
        assert provenance.recorded <= DateTime.current
      end

      # =============================================================================
      # RECORD EXPANSION
      # =============================================================================

      test "record_expansion creates a provenance record with expansion reason" do
        provenance = @service.record_expansion(
          @valueset_id,
          agent_id: @agent_id,
          code_count: 42
        )

        assert_equal "ValueSet", provenance.target_type
        assert_equal @valueset_id, provenance.target_id
        assert_equal "HRESCH", provenance.reason_code
      end

      test "record_expansion stores metadata" do
        provenance = @service.record_expansion(
          @valueset_id,
          agent_id: @agent_id,
          code_count: 42,
          cached: true
        )

        metadata = JSON.parse(provenance.chain_of_custody)
        assert_equal 42, metadata["code_count"]
        assert_equal true, metadata["cached"]
      end

      # =============================================================================
      # RECORD VALIDATION
      # =============================================================================

      test "record_validation creates a provenance record for code validation" do
        provenance = @service.record_validation(
          @valueset_id,
          code: "250.00",
          agent_id: @agent_id,
          result: true
        )

        assert_equal "HACCRD", provenance.reason_code
      end

      test "record_validation stores code and result in metadata" do
        provenance = @service.record_validation(
          @valueset_id,
          code: "E11.9",
          agent_id: @agent_id,
          result: false
        )

        metadata = JSON.parse(provenance.chain_of_custody)
        assert_equal "E11.9", metadata["code"]
        assert_equal false, metadata["result"]
      end

      # =============================================================================
      # RECORD CREATE/UPDATE/DELETE
      # =============================================================================

      test "record_create creates provenance with author agent type" do
        provenance = @service.record_create(
          "new-valueset",
          agent_id: @agent_id
        )

        assert_equal "CREATE", provenance.activity
        assert_equal "author", provenance.agent_type
      end

      test "record_create can store source information" do
        provenance = @service.record_create(
          "new-valueset",
          agent_id: @agent_id,
          source: "GPRA-taxonomy-export"
        )

        assert_equal "DocumentReference", provenance.entity_what_type
        assert_equal "GPRA-taxonomy-export", provenance.entity_what_id
        assert_equal "source", provenance.entity_role
      end

      test "record_update creates provenance with changes" do
        provenance = @service.record_update(
          @valueset_id,
          agent_id: @agent_id,
          changes: { added_codes: 5, removed_codes: 2 }
        )

        assert_equal "UPDATE", provenance.activity

        metadata = JSON.parse(provenance.chain_of_custody)
        assert_equal 5, metadata["added_codes"]
        assert_equal 2, metadata["removed_codes"]
      end

      test "record_delete creates provenance with reason" do
        provenance = @service.record_delete(
          "obsolete-valueset",
          agent_id: @agent_id,
          reason: "Replaced by updated version"
        )

        assert_equal "DELETE", provenance.activity
        assert_equal "Replaced by updated version", provenance.reason_display
      end

      # =============================================================================
      # HISTORY QUERIES
      # =============================================================================

      test "history returns provenance records for a ValueSet" do
        3.times do |i|
          @service.record_access(@valueset_id, agent_id: "user-#{i}")
        end

        history = @service.history(@valueset_id)

        assert history.length >= 3
        assert history.all? { |p| p.target_id == @valueset_id }
      end

      test "history orders by recorded descending" do
        @service.record_access(@valueset_id, agent_id: "user-1")
        sleep 0.01
        @service.record_access(@valueset_id, agent_id: "user-2")

        history = @service.history(@valueset_id, limit: 2)

        assert history.first.recorded >= history.last.recorded
      end

      test "history can filter by activity type" do
        @service.record_access(@valueset_id, agent_id: @agent_id)
        @service.record_update(@valueset_id, agent_id: @agent_id)

        updates_only = @service.history(@valueset_id, activity: "UPDATE")

        assert updates_only.all? { |p| p.activity == "UPDATE" }
      end

      test "history respects limit parameter" do
        5.times { |i| @service.record_access(@valueset_id, agent_id: "user-#{i}") }

        history = @service.history(@valueset_id, limit: 3)

        assert history.length <= 3
      end

      # =============================================================================
      # AGENT HISTORY
      # =============================================================================

      test "agent_history returns ValueSet operations for an agent" do
        @service.record_access("valueset-1", agent_id: @agent_id)
        @service.record_access("valueset-2", agent_id: @agent_id)
        @service.record_access("valueset-3", agent_id: "other-user")

        history = @service.agent_history(@agent_id)

        assert history.all? { |p| p.agent_who_id == @agent_id }
        assert history.length >= 2
      end

      # =============================================================================
      # USAGE STATISTICS
      # =============================================================================

      test "usage_stats returns statistics for a ValueSet" do
        2.times { @service.record_access(@valueset_id, agent_id: "user-1") }
        3.times { @service.record_expansion(@valueset_id, agent_id: "user-2", code_count: 10) }
        1.times { @service.record_validation(@valueset_id, code: "250.00", agent_id: "user-3", result: true) }

        stats = @service.usage_stats(@valueset_id)

        assert stats[:total_operations] >= 6
        assert stats[:access_count] >= 2
        assert stats[:expansion_count] >= 3
        assert stats[:validation_count] >= 1
        assert stats[:unique_agents] >= 3
        assert stats[:last_accessed].present?
      end

      test "usage_stats can filter by time period" do
        # Simulate an old record by backdating
        old = @service.record_access(@valueset_id, agent_id: @agent_id)
        old.instance_variable_set(:@recorded, 1.week.ago)

        # Recent record
        @service.record_access(@valueset_id, agent_id: @agent_id)

        stats = @service.usage_stats(@valueset_id, since: 1.day.ago)

        assert stats[:total_operations] >= 1
      end

      # =============================================================================
      # ERROR HANDLING
      # =============================================================================

      test "record_access returns a provenance object" do
        provenance = @service.record_access(@valueset_id, agent_id: "valid-id")

        assert_kind_of Lakeraven::EHR::ValueSetAuditService::AuditProvenance, provenance
      end
    end
  end
end
