# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      # FHIR R4 conformance + honesty of the Provenance serialization:
      # agent.type is 0..1 CodeableConcept (NOT an array), `recorded` is
      # when the provenance statement was recorded (not the observation's
      # clinical time — that is occurredDateTime), and a non-office
      # capture modality is never dressed up as a patient informant.
      class ObservationProvenanceSerializerTest < ActiveSupport::TestCase
        RECORDED_AT = Time.utc(2026, 9, 1, 12, 0)
        CLINICAL_AT = Time.utc(2025, 1, 15, 8, 30)

        def observation(overrides = {})
          Observation.new({
            ien: "5001", patient_dfn: "1", code: "85354-9",
            effective_datetime: CLINICAL_AT, service_category: "A",
            provider_name: "PROVIDER,TEST"
          }.merge(overrides))
        end

        def serialize(overrides = {})
          ObservationProvenanceSerializer.call(observation(overrides), recorded_at: RECORDED_AT)
        end

        test "agent.type is a single CodeableConcept, not an array" do
          agent = serialize[:agent].first

          assert agent[:type].is_a?(Hash), "R4 Provenance.agent.type is 0..1 CodeableConcept"
          assert_equal "author", agent[:type][:coding].first[:code]
        end

        test "recorded is the provenance-statement instant; clinical time is occurredDateTime" do
          provenance = serialize

          assert_equal RECORDED_AT.iso8601, provenance[:recorded]
          assert_equal CLINICAL_AT.iso8601, provenance[:occurredDateTime]
          refute_equal provenance[:recorded], provenance[:occurredDateTime]
        end

        test "office capture emits author agent naming the recording provider" do
          agent = serialize[:agent].first

          assert_equal "PROVIDER,TEST", agent[:who][:display]
        end

        test "office capture without a provider name uses a facility display, never an invented id" do
          agent = serialize(provider_name: nil)[:agent].first

          assert_nil agent[:who][:reference]
          assert_match(/facility/i, agent[:who][:display])
        end

        test "telecom capture asserts modality, no agent type, and no patient informant" do
          provenance = serialize(service_category: "T")

          agent = provenance[:agent].first
          assert_nil agent[:type], "capture modality proves no participant role"
          assert_nil agent[:who][:reference], "the wire does not establish an informant"
          assert_match(/not office-measured/i, agent[:who][:display])
          assert_match(/telecommunications/i, agent[:who][:display])
          activity = provenance[:activity][:coding].first
          assert_equal "T", activity[:code]
        end

        test "every reported modality code serializes without a patient reference" do
          %w[T M E C].each do |category|
            provenance = serialize(service_category: category)
            refute_nil provenance, "category #{category} must yield Provenance"
            provenance[:agent].each do |agent|
              refute agent.dig(:who, :reference).to_s.start_with?("Patient/"),
                "category #{category} must not invent who=Patient"
            end
          end
        end

        test "unknown or absent capture context yields no Provenance" do
          assert_nil serialize(service_category: nil)
          assert_nil serialize(service_category: "N")
          assert_nil serialize(service_category: "X")
          assert_nil serialize(service_category: "ZZ")
        end

        test "an observation without an id yields no Provenance" do
          assert_nil serialize(ien: nil)
          assert_nil serialize(ien: "")
        end

        test "id and target derive from the measurement IEN" do
          provenance = serialize

          assert_equal "prov-5001", provenance[:id]
          assert_equal [ { reference: "Observation/5001" } ], provenance[:target]
        end
      end
    end
  end
end
