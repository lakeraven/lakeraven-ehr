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

      # The HTML chart renders the raw vitals hashes directly, so reading them
      # straight from the gateway skipped the ownership check the FHIR paths
      # apply to the same rows -- a second door onto the same data.
      test "the raw wire vitals the HTML chart renders are compartment-checked" do
        original = ObservationGateway.method(:for_patient)
        ObservationGateway.define_singleton_method(:for_patient) do |_dfn|
          [ { type: "P", value: "72", patient_dfn: "2" },
            { type: "T", value: "37" } ]
        end

        rows = SupplementalClinicalResources.wire_vital_rows_for_patient(DFN)
        refute_empty rows, "the unstated-owner row belongs to the requested patient"
        assert_equal [ "T" ], rows.map { |r| r[:type] },
          "the row naming patient 2 must not reach the chart"
      ensure
        ObservationGateway.define_singleton_method(:for_patient, original)
      end

      # Preferring a non-nil symbol value let a blank one mask a stated
      # string-keyed owner, so the row read as ownerless and was adopted.
      test "a blank symbol key cannot mask a stated string-keyed owner" do
        original = ObservationGateway.method(:for_patient)
        ObservationGateway.define_singleton_method(:for_patient) do |_dfn|
          [ { patient_dfn: "", "patient_dfn" => "2", type: "P", value: "72" } ]
        end

        assert_empty SupplementalClinicalResources.wire_vital_rows_for_patient(DFN),
          "the string key states patient 2; a blank symbol key is not a denial of that"
      ensure
        ObservationGateway.define_singleton_method(:for_patient, original)
      end

      # A subclass can override to_fhir to emit a different resource type, and an
      # object can override is_a? to pass a check it should fail. Only the
      # engine's own model is accepted.
      test "a subclass of the expected model is not accepted" do
        subclass = Class.new(AllergyIntolerance)
        impostor = subclass.new(ien: "sub-1", patient_dfn: DFN, allergen: "Drug",
                                category: "medication")

        with_allergy_gateway([]) do
          with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ impostor ] }) do
            assert_empty SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
          end
        end
      end

      # Ownership is not enough. A resource of the WRONG TYPE that owns the right
      # patient would be serialized into the other endpoint's bundle, which
      # breaks the resource-type contract a FHIR client relies on, and an object
      # of no known type fails later, outside the provider-error wrapper where
      # the failure no longer names a cause.
      test "the observation provider cannot contribute an AllergyIntolerance" do
        intruder = AllergyIntolerance.new(ien: "wrong-type", patient_dfn: DFN,
                                          allergen: "Drug", category: "medication")

        with_supplemental_providers(observations: ->(_dfn) { [ intruder ] }) do
          results = SupplementalClinicalResources.merged_observations_for_patient(DFN)
          refute_includes results.map { |r| r.ien.to_s }, "wrong-type",
            "an AllergyIntolerance must not be served in an Observation bundle"
          assert(results.all? { |r| r.is_a?(Observation) },
            "every row in an Observation result must be an Observation")
        end
      end

      test "the allergy provider cannot contribute an Observation" do
        intruder = Observation.new(ien: "wrong-type", patient_dfn: DFN, code: "8310-5",
                                   display: "Body temperature", value: "37")

        with_allergy_gateway([]) do
          with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ intruder ] }) do
            results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
            assert_empty results,
              "an Observation must not be served in an AllergyIntolerance bundle"
          end
        end
      end

      test "an object of no known type is dropped rather than failing downstream" do
        junk = Struct.new(:ien, :patient_dfn).new("junk", DFN)

        with_supplemental_providers(observations: ->(_dfn) { [ junk ] }) do
          results = SupplementalClinicalResources.merged_observations_for_patient(DFN)
          refute_includes results.map { |r| r.ien.to_s }, "junk"
        end
      end

      # An RxCUI is a numeric concept id. Publishing any non-blank string under
      # the RxNorm system URI asserts something false about it, and a consumer
      # trusts the system URI.
      test "only an RxCUI is served as an RxNorm coding" do
        [ "not-rxnorm", " ", "723x", "", "rx723" ].each do |bad|
          allergy = AllergyIntolerance.new(ien: "c", patient_dfn: DFN, allergen: "Amoxicillin",
                                           allergen_code: bad, category: "medication")
          assert_nil allergy.to_fhir[:code][:coding],
            "#{bad.inspect} is not an RxCUI and must not be published as one"
          assert_equal "Amoxicillin", allergy.to_fhir[:code][:text],
            "the allergen must still survive as text"
        end
      end

      test "a padded RxCUI is served trimmed, not dropped" do
        allergy = AllergyIntolerance.new(ien: "c", patient_dfn: DFN, allergen: "Amoxicillin",
                                         allergen_code: " 723 ", category: "medication")
        coding = allergy.to_fhir[:code][:coding]
        refute_nil coding, "a padded RxCUI is still an RxCUI"
        assert_equal "723", coding.first[:code]
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
