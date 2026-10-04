# frozen_string_literal: true

require "test_helper"

# Per-patient scoping at the supplemental seam, for the representation and
# lifetime cases an independent review raised. Each of these passed the suite
# before the fix, so each is a regression guard rather than a restatement.
module Lakeraven
  module EHR
    class CompartmentEdgeCasesTest < ActiveSupport::TestCase
      include SupplementalProviderConfigHelper

      DFN = "1"

      def gateway_returning(rows)
        Class.new do
          define_singleton_method(:for_patient) { |_dfn| rows }
        end
      end

      def with_allergy_gateway(rows)
        original = AllergyIntolerance.gateway
        AllergyIntolerance.gateway = gateway_returning(rows)
        yield
      ensure
        AllergyIntolerance.gateway = original
      end

      # PatientRepository.find resolves a DFN with to_i, so these are the SAME
      # patient. Comparing raw strings would drop a row that is genuinely this
      # patient's because the wire wrote it "01".
      test "an owned supplemental row is kept whatever the dfn's representation" do
        [ 1, "1", "01", " 1 " ].each do |owner|
          owned = AllergyIntolerance.new(ien: "s-#{owner.to_s.strip}", patient_dfn: owner,
                                         allergen: "Drug", category: "medication")
          with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ owned ] }) do
            results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
            assert_includes results.map { |r| r.ien.to_s }, "s-#{owner.to_s.strip}",
              "owner #{owner.inspect} is patient 1 by to_i, so it must not be dropped"
          end
        end
      end

      test "a foreign supplemental row is dropped whatever the dfn's representation" do
        [ 2, "2", "02", " 2 " ].each do |owner|
          foreign = AllergyIntolerance.new(ien: "f-row", patient_dfn: owner,
                                           allergen: "Foreign", category: "medication")
          with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ foreign ] }) do
            results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
            refute_includes results.map { |r| r.ien.to_s }, "f-row",
              "owner #{owner.inspect} is not patient 1"
          end
        end
      end

      # Hashes reach the seam from several RPC mappings, some string-keyed. Reading
      # only symbol keys treats a stated owner as absent and lets the row be
      # adopted by whichever patient was asked for.
      test "a string-keyed wire row stating another patient is not adopted" do
        with_allergy_gateway([ { "ien" => "sk-1", "patient_dfn" => "2", "allergen" => "Foreign" } ]) do
          results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
          # Assert on the COUNT, not on the field values. Reading only symbol
          # keys makes every field of this row invisible, so it leaks through as
          # a blank allergy that matches no field assertion -- a leaked record
          # all the same.
          assert_empty results,
            "a string-keyed row stating patient 2 must not appear in patient 1's results"
        end
      end

      # The ownership check and the serialization are separate reads. An object
      # whose patient_dfn changes in between must not be able to serialize a
      # foreign reference after passing the check.
      test "a row that changes its owner after the check cannot serialize a foreign patient" do
        mutable = AllergyIntolerance.new(ien: "m-1", patient_dfn: DFN, allergen: "Drug",
                                         category: "medication")

        with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ mutable ] }) do
          results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
          assert_includes results.map { |r| r.ien.to_s }, "m-1"

          mutable.patient_dfn = "2" # the provider still holds the object
          served = results.find { |r| r.ien.to_s == "m-1" }
          assert_equal DFN, served.patient_dfn.to_s,
            "what was checked must be what is served"
          assert_equal "Patient/#{DFN}", served.to_fhir[:patient][:reference]
        end
      end

      # A blank id is not an identity, so blanks must not collide with each other.
      test "two owned rows with no id both survive the id de-duplication" do
        a = AllergyIntolerance.new(ien: "", patient_dfn: DFN, allergen: "Alpha", category: "medication")
        b = AllergyIntolerance.new(ien: "", patient_dfn: DFN, allergen: "Beta", category: "medication")

        with_allergy_gateway([]) do
          with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ a, b ] }) do
            results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
            assert_equal %w[Alpha Beta], results.map(&:allergen).sort,
              "a blank id is not an identity; neither row should shadow the other"
          end
        end
      end

      test "two supplemental rows cannot both claim the same id" do
        a = AllergyIntolerance.new(ien: "dup", patient_dfn: DFN, allergen: "First", category: "medication")
        b = AllergyIntolerance.new(ien: "dup", patient_dfn: DFN, allergen: "Second", category: "medication")

        with_allergy_gateway([]) do
          with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ a, b ] }) do
            results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
            assert_equal 1, results.count { |r| r.ien.to_s == "dup" }
          end
        end
      end

      # Observation.from_vital_hashes stamps the requested DFN and discards what
      # the row said, so a foreign row has to be rejected before conversion.
      test "a wire observation stating another patient is not converted into this one" do
        original = ObservationGateway.method(:for_patient)
        ObservationGateway.define_singleton_method(:for_patient) do |_dfn|
          [ { type: "P", value: "72", patient_dfn: "2" } ]
        end
        results = SupplementalClinicalResources.merged_observations_for_patient(DFN)
        assert_empty results, "a vitals row naming patient 2 must not be served as patient 1's"
      ensure
        ObservationGateway.define_singleton_method(:for_patient, original)
      end

      test "a wire observation with no stated patient is still served" do
        original = ObservationGateway.method(:for_patient)
        ObservationGateway.define_singleton_method(:for_patient) do |_dfn|
          [ { type: "P", value: "72" } ]
        end
        results = SupplementalClinicalResources.merged_observations_for_patient(DFN)
        refute_empty results, "the RPC was queried for this patient; an unstated owner is theirs"
      ensure
        ObservationGateway.define_singleton_method(:for_patient, original)
      end
    end
  end
end
