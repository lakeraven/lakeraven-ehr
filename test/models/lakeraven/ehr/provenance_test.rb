# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ProvenanceTest < ActiveSupport::TestCase
      # =============================================================================
      # ATTRIBUTES
      # =============================================================================

      test "tracks target and agent" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           activity: "CREATE", recorded: Time.current)
        assert_equal "Patient", p.target_type
        assert_equal "1", p.target_id
        assert_equal "101", p.agent_who_id
        assert_equal "Practitioner", p.agent_who_type
        assert_equal "CREATE", p.activity
      end

      test "recorded is a datetime" do
        now = Time.current
        p = Provenance.new(recorded: now)
        assert_in_delta now.to_f, p.recorded.to_f, 1.0
      end

      test "auto-sets recorded when not provided" do
        p = Provenance.new(target_type: "Patient", target_id: "1", agent_who_id: "101")
        p.valid?
        assert p.recorded.present?
      end

      # =============================================================================
      # VALIDATIONS
      # =============================================================================

      test "valid with required attributes" do
        p = Provenance.new(
          target_type: "ServiceRequest", target_id: "1001",
          recorded: DateTime.current, agent_who_id: "101"
        )
        assert p.valid?
      end

      test "requires target_type" do
        p = Provenance.new(target_id: "1001", recorded: DateTime.current, agent_who_id: "101")
        refute p.valid?
        assert p.errors[:target_type].any?
      end

      test "requires target_id" do
        p = Provenance.new(target_type: "ServiceRequest", recorded: DateTime.current, agent_who_id: "101")
        refute p.valid?
        assert p.errors[:target_id].any?
      end

      test "requires agent_who_id" do
        p = Provenance.new(target_type: "ServiceRequest", target_id: "1001", recorded: DateTime.current)
        refute p.valid?
        assert p.errors[:agent_who_id].any?
      end

      test "validates activity is in allowed list" do
        p = Provenance.new(
          target_type: "ServiceRequest", target_id: "1001",
          recorded: DateTime.current, agent_who_id: "101",
          activity: "INVALID"
        )
        refute p.valid?
        assert p.errors[:activity].any?
      end

      test "allows valid activities" do
        %w[CREATE UPDATE DELETE].each do |act|
          p = Provenance.new(
            target_type: "Patient", target_id: "1",
            agent_who_id: "101", activity: act
          )
          assert p.valid?, "Expected #{act} to be valid"
        end
      end

      test "allows nil activity" do
        p = Provenance.new(
          target_type: "Patient", target_id: "1", agent_who_id: "101"
        )
        assert p.valid?
      end

      # =============================================================================
      # ACTIVITY PREDICATES
      # =============================================================================

      test "create? returns true for CREATE" do
        assert Provenance.new(activity: "CREATE").create?
      end

      test "update? returns true for UPDATE" do
        assert Provenance.new(activity: "UPDATE").update?
      end

      test "delete? returns true for DELETE" do
        assert Provenance.new(activity: "DELETE").delete?
      end

      test "activity_display returns human-readable form" do
        assert_equal "Create", Provenance.new(activity: "CREATE").activity_display
        assert_equal "Update", Provenance.new(activity: "UPDATE").activity_display
        assert_equal "Delete", Provenance.new(activity: "DELETE").activity_display
      end

      # =============================================================================
      # AGENT TYPE
      # =============================================================================

      test "agent_type_display returns human-readable form" do
        assert_equal "Author", Provenance.new(agent_type: "author").agent_type_display
        assert_equal "Performer", Provenance.new(agent_type: "performer").agent_type_display
      end

      # =============================================================================
      # ENTITY TRACKING
      # =============================================================================

      test "has_entity? true when entity fields present" do
        p = Provenance.new(
          target_type: "ServiceRequest", target_id: "1001",
          agent_who_id: "101",
          entity_role: "derivation",
          entity_what_type: "ServiceRequest", entity_what_id: "1000"
        )
        assert p.has_entity?
      end

      test "has_entity? false when no entity" do
        p = Provenance.new(
          target_type: "ServiceRequest", target_id: "1001",
          agent_who_id: "101"
        )
        refute p.has_entity?
      end

      # =============================================================================
      # FHIR SERIALIZATION
      # =============================================================================

      test "to_fhir returns Provenance resource" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           recorded: Time.current)
        fhir = p.to_fhir
        assert_equal "Provenance", fhir[:resourceType]
      end

      test "to_fhir includes target reference" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101")
        assert_equal "Patient/1", p.to_fhir[:target].first[:reference]
      end

      test "to_fhir includes recorded timestamp" do
        now = Time.current
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           recorded: now)
        assert_equal now.iso8601, p.to_fhir[:recorded]
      end

      test "to_fhir includes activity coding for CREATE" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           activity: "CREATE")
        fhir = p.to_fhir
        assert fhir[:activity].present?
        assert_equal "CREATE", fhir[:activity][:coding].first[:code]
      end

      test "to_fhir omits activity when nil" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101")
        assert_nil p.to_fhir[:activity]
      end

      test "to_fhir includes agent who reference" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101")
        assert_equal "Practitioner/101", p.to_fhir[:agent].first[:who][:reference]
      end

      test "to_fhir includes agent type" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           agent_type: "author")
        fhir = p.to_fhir
        assert_equal "author", fhir[:agent].first[:type]&.first&.dig(:coding, 0, :code)
      end

      test "to_fhir agent_who_type supports Organization" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Organization", agent_who_id: "1")
        assert_equal "Organization/1", p.to_fhir[:agent].first[:who][:reference]
      end

      test "to_fhir target supports multiple resource types" do
        %w[Patient Encounter MedicationRequest Immunization].each do |type|
          p = Provenance.new(target_type: type, target_id: "42",
                             agent_who_type: "Practitioner", agent_who_id: "1")
          assert_equal "#{type}/42", p.to_fhir[:target].first[:reference]
        end
      end

      test "to_fhir always includes recorded (auto-set)" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101")
        assert p.to_fhir[:recorded].present?
      end

      test "to_fhir includes entity when present" do
        p = Provenance.new(
          target_type: "ServiceRequest", target_id: "1001",
          agent_who_type: "Practitioner", agent_who_id: "101",
          entity_role: "derivation",
          entity_what_type: "ServiceRequest", entity_what_id: "1000"
        )
        fhir = p.to_fhir
        entity = fhir[:entity]&.first
        assert_not_nil entity
        assert_equal "derivation", entity[:role]
        assert_equal "ServiceRequest/1000", entity[:what][:reference]
      end

      test "to_fhir omits entity when not present" do
        p = Provenance.new(
          target_type: "Patient", target_id: "1",
          agent_who_type: "Practitioner", agent_who_id: "101"
        )
        assert_nil p.to_fhir[:entity]
      end
    end
  end
end
