# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ProvenanceTest < ActiveSupport::TestCase
      test "tracks target and agent" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           activity: "create", recorded: Time.current)
        assert_equal "Patient", p.target_type
        assert_equal "101", p.agent_who_id
      end

      test "to_fhir returns Provenance resource" do
        p = Provenance.new(target_type: "Patient", target_id: "1",
                           agent_who_type: "Practitioner", agent_who_id: "101",
                           recorded: Time.current)
        fhir = p.to_fhir
        assert_equal "Provenance", fhir[:resourceType]
        assert_equal "Patient/1", fhir[:target].first[:reference]
      end
    end
  end
end
