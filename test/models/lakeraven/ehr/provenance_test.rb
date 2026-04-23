# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ProvenanceTest < ActiveSupport::TestCase
      # -- Attributes ----------------------------------------------------------

      test "tracks target and agent" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           activity: "create", recorded: Time.current)
        assert_equal "Patient", p.target_type
        assert_equal "1", p.target_id
        assert_equal "101", p.agent_who_id
        assert_equal "Practitioner", p.agent_who_type
        assert_equal "create", p.activity
      end

      test "recorded is a datetime" do
        now = Time.current
        p = Provenance.new(recorded: now)
        assert_in_delta now.to_f, p.recorded.to_f, 1.0
      end

      # -- FHIR serialization --------------------------------------------------

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
        fhir = p.to_fhir
        assert_equal "Patient/1", fhir[:target].first[:reference]
      end

      test "to_fhir includes recorded timestamp" do
        now = Time.current
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           recorded: now)
        fhir = p.to_fhir
        assert_equal now.iso8601, fhir[:recorded]
      end

      test "to_fhir includes activity when present" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           activity: "create")
        fhir = p.to_fhir
        assert_equal "create", fhir[:activity][:text]
      end

      test "to_fhir omits activity when nil" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           activity: nil)
        fhir = p.to_fhir
        assert_nil fhir[:activity]
      end

      test "to_fhir includes agent who reference" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101")
        fhir = p.to_fhir
        assert_equal "Practitioner/101", fhir[:agent].first[:who][:reference]
      end

      test "to_fhir agent_who_type supports Organization" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Organization", agent_who_id: "1")
        fhir = p.to_fhir
        assert_equal "Organization/1", fhir[:agent].first[:who][:reference]
      end

      test "to_fhir target supports different resource types" do
        %w[Patient Encounter MedicationRequest Immunization].each do |type|
          p = Provenance.new(target_type: type, target_id: "42",
                             agent_who_type: "Practitioner", agent_who_id: "1")
          fhir = p.to_fhir
          assert_equal "#{type}/42", fhir[:target].first[:reference]
        end
      end

      test "to_fhir omits recorded when nil" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           recorded: nil)
        fhir = p.to_fhir
        assert_nil fhir[:recorded]
      end
    end
  end
end
