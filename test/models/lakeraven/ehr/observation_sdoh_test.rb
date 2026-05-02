# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ObservationSdohTest < ActiveSupport::TestCase
      test "defines SDOH screening LOINC codes" do
        assert Observation::SDOH_CODES.is_a?(Hash)
        assert Observation::SDOH_CODES.key?(:housing_status)
        assert Observation::SDOH_CODES.key?(:food_insecurity)
      end

      test "social-history observation is SDOH" do
        obs = Observation.new(patient_dfn: "1", display: "Housing status", category: "social-history")
        assert obs.sdoh?
      end

      test "survey observation is SDOH" do
        obs = Observation.new(patient_dfn: "1", display: "SDOH screening", category: "survey")
        assert obs.sdoh?
      end

      test "vital-signs observation is not SDOH" do
        obs = Observation.new(patient_dfn: "1", display: "Blood pressure", category: "vital-signs")
        refute obs.sdoh?
      end

      test "SDOH observation to_fhir has correct category coding" do
        obs = Observation.new(
          patient_dfn: "1", display: "Housing status",
          category: "social-history", code: "71802-3"
        )
        fhir = obs.to_fhir

        cat = fhir[:category]&.first
        refute_nil cat
        assert_equal "social-history", cat[:coding].first[:code]
      end

      test "SDOH observation has LOINC-coded code" do
        obs = Observation.new(
          patient_dfn: "1", display: "Housing status",
          category: "social-history", code: "71802-3", code_system: "loinc"
        )
        fhir = obs.to_fhir

        code_coding = fhir[:code][:coding]&.first
        refute_nil code_coding
        assert_equal "71802-3", code_coding[:code]
        assert_equal "http://loinc.org", code_coding[:system]
      end

      test "SDOH observation has valueString for text answers" do
        obs = Observation.new(
          patient_dfn: "1", display: "Housing status",
          category: "social-history", code: "71802-3",
          value: "Permanently housed"
        )
        fhir = obs.to_fhir

        assert_equal "Permanently housed", fhir[:valueString]
      end

      test "SDOH observation has patient reference" do
        obs = Observation.new(
          patient_dfn: "123", display: "Food insecurity",
          category: "social-history", code: "88122-7"
        )
        fhir = obs.to_fhir

        assert_equal "Patient/123", fhir[:subject][:reference]
      end
    end
  end
end
