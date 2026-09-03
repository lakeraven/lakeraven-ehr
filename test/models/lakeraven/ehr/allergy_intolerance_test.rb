# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AllergyIntoleranceTest < ActiveSupport::TestCase
      # -- Attributes ----------------------------------------------------------

      test "has required attributes" do
        ai = AllergyIntolerance.new(
          ien: "1", patient_dfn: "100", allergen: "Penicillin",
          reaction: "Rash", severity: "moderate", category: "medication"
        )
        assert_equal "1", ai.ien
        assert_equal "Penicillin", ai.allergen
        assert_equal "Rash", ai.reaction
        assert_equal "moderate", ai.severity
        assert_equal "medication", ai.category
      end

      test "defaults clinical_status to active" do
        ai = AllergyIntolerance.new
        assert_equal "active", ai.clinical_status
      end

      # -- Predicates ----------------------------------------------------------

      test "active? true when active" do
        assert AllergyIntolerance.new(clinical_status: "active").active?
      end

      test "active? false when inactive" do
        refute AllergyIntolerance.new(clinical_status: "inactive").active?
      end

      test "medication? true for medication category" do
        assert AllergyIntolerance.new(category: "medication").medication?
      end

      test "medication? false for food category" do
        refute AllergyIntolerance.new(category: "food").medication?
      end

      test "food? true for food category" do
        assert AllergyIntolerance.new(category: "food").food?
      end

      test "food? false for medication category" do
        refute AllergyIntolerance.new(category: "medication").food?
      end

      # -- Class methods -------------------------------------------------------

      test "for_patient returns allergies" do
        results = AllergyIntolerance.for_patient(1)
        assert_kind_of Array, results
      end

      # -- Gateway DI ----------------------------------------------------------

      test "gateway is configurable" do
        assert AllergyIntolerance.respond_to?(:gateway)
        assert AllergyIntolerance.respond_to?(:gateway=)
      end

      test "gateway defaults to AllergyIntoleranceGateway" do
        assert_equal AllergyIntoleranceGateway, AllergyIntolerance.gateway
      end

      test "for_patient delegates to gateway" do
        mock_gw = Object.new
        def mock_gw.for_patient(_dfn)
          [ Lakeraven::EHR::AllergyIntolerance.new(ien: "99", allergen: "MOCK") ]
        end

        original = AllergyIntolerance.gateway
        begin
          AllergyIntolerance.gateway = mock_gw
          results = AllergyIntolerance.for_patient(1)
          assert_equal 1, results.length
          assert_equal "MOCK", results.first.allergen
        ensure
          AllergyIntolerance.gateway = original
        end
      end

      # -- FHIR serialization --------------------------------------------------

      test "to_fhir returns AllergyIntolerance resource" do
        ai = AllergyIntolerance.new(
          ien: "1", patient_dfn: "100", allergen: "Penicillin",
          clinical_status: "active"
        )
        fhir = ai.to_fhir
        assert_equal "AllergyIntolerance", fhir[:resourceType]
      end

      test "to_fhir includes clinical status" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Aspirin", clinical_status: "active"
        )
        fhir = ai.to_fhir
        assert_equal "active", fhir.dig(:clinicalStatus, :coding, 0, :code)
      end

      test "to_fhir includes allergen text" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Latex"
        )
        fhir = ai.to_fhir
        assert_equal "Latex", fhir.dig(:code, :text)
      end

      test "to_fhir includes patient reference" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Peanuts"
        )
        fhir = ai.to_fhir
        assert_equal "Patient/100", fhir.dig(:patient, :reference)
      end

      test "to_fhir includes reaction when present" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Penicillin",
          reaction: "Anaphylaxis", severity: "severe"
        )
        fhir = ai.to_fhir
        assert_equal 1, fhir[:reaction].length
        assert_equal "Anaphylaxis", fhir[:reaction].first[:manifestation].first[:text]
        assert_equal "severe", fhir[:reaction].first[:severity]
      end

      test "to_fhir omits reaction when no reaction (FHIR forbids empty arrays)" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Shellfish", reaction: nil
        )
        fhir = ai.to_fhir
        refute fhir.key?(:reaction)
      end

      test "to_fhir includes criticality when present" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Bee Stings", criticality: "high"
        )
        fhir = ai.to_fhir
        assert_equal "high", fhir[:criticality]
      end

      test "to_fhir omits criticality when absent or not a legal code" do
        refute AllergyIntolerance.new(patient_dfn: "100", allergen: "X").to_fhir.key?(:criticality)
        refute AllergyIntolerance.new(patient_dfn: "100", allergen: "X", criticality: "SEVERE!")
          .to_fhir.key?(:criticality)
      end

      test "to_fhir includes an RxNorm coding when allergen_code present" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Penicillin G", allergen_code: "7980"
        )
        coding = ai.to_fhir.dig(:code, :coding, 0)
        assert_equal "http://www.nlm.nih.gov/research/umls/rxnorm", coding[:system]
        assert_equal "7980", coding[:code]
        assert_equal "Penicillin G", coding[:display]
      end

      test "to_fhir omits coding when no allergen_code" do
        refute AllergyIntolerance.new(patient_dfn: "100", allergen: "Latex").to_fhir[:code].key?(:coding)
      end

      # -- Wire mapping (ORQQAL LIST) ------------------------------------------

      test "from_rpc_hashes builds models with deterministic ids" do
        allergies = AllergyIntolerance.from_rpc_hashes(
          [ { allergen: "PENICILLIN G", reaction: "Hives", severity: "Moderate" } ],
          patient_dfn: 100
        )
        ai = allergies.first
        assert_equal "allergy-100-penicillin-g", ai.ien
        assert_equal "100", ai.patient_dfn
        assert_equal "active", ai.clinical_status
        assert_equal "moderate", ai.to_fhir[:reaction].first[:severity]
      end
    end
  end
end
