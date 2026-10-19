# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class SupplementalClinicalResourcesDedupTest < ActiveSupport::TestCase
      include SupplementalProviderConfigHelper

      DFN = "1"

      # Mirrors AllergyIntoleranceGateway assessment capture so wire_allergy_reply
      # sees assessed NKA with an empty allergy list.
      class NkaWireGateway
        class << self
          attr_accessor :patient_wire_rows

          def begin_assessment_capture!
            @capture = true
            @mark = nil
          end

          def end_assessment_capture!
            @capture = false
          end

          def for_patient(_dfn)
            rows = patient_wire_rows.nil? ? [] : Array(patient_wire_rows)
            if @capture
              @mark = if rows.empty?
                { assessed: true, nka: true, rows: rows }
              else
                { assessed: true, nka: false, rows: rows }
              end
            end
            rows
          end

          def take_assessment(rows)
            return unless @mark && @mark[:rows].equal?(rows)

            { assessed: @mark[:assessed], nka: @mark[:nka] }
          end
        end
      end

      def with_nka_wire_gateway(wire_rows: nil)
        original = AllergyIntolerance.gateway
        NkaWireGateway.patient_wire_rows = wire_rows
        AllergyIntolerance.gateway = NkaWireGateway
        yield
      ensure
        AllergyIntolerance.gateway = original
        NkaWireGateway.patient_wire_rows = nil
      end

      def allergy_reading_for_patient(dfn, supplemental_rows, wire_rows: nil)
        with_nka_wire_gateway(wire_rows: wire_rows) do
          with_supplemental_providers(allergy_intolerances: ->(_dfn) { supplemental_rows }) do
            SupplementalClinicalResources.send(:allergy_intolerance_reading_for_patient, dfn)
          end
        end
      end

      test "differing duplicate ien increments dropped_count" do
        latex = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Latex", clinical_status: "active"
        )
        peanut = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Peanut", clinical_status: "active"
        )

        reading = allergy_reading_for_patient(DFN, [ latex, peanut ])

        assert_equal 1, reading.size
        assert_includes reading.map(&:allergen), "Latex"
        assert reading.dropped_count >= 1,
               "expected merge de-dupe of differing matching_key rows to count as dropped"
      end

      test "same-allergy duplicate ien does not add to dropped_count" do
        single = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Latex", clinical_status: "active"
        )
        baseline = allergy_reading_for_patient(DFN, [ single ])

        duplicate_a = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Latex", clinical_status: "active"
        )
        duplicate_b = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Latex", clinical_status: "active"
        )
        with_duplicates = allergy_reading_for_patient(DFN, [ duplicate_a, duplicate_b ])

        assert_equal baseline.dropped_count, with_duplicates.dropped_count,
                     "same matching_key duplicate must not increase dropped_count"
        assert_equal 1, with_duplicates.size
        assert_equal [ "Latex" ], with_duplicates.map(&:allergen)
      end

      # Pin: two rows sharing an ien are the SAME allergy when (a) both carry
      # allergen_code and codes match, or (b) at least one has no allergen_code
      # and allergen names match after downcase/strip/whitespace squish. They are
      # DIFFERENT (counted dropped) when both coded with different codes, names
      # differ under (b), or a needed name is blank. Do not key same-ien solely
      # on AllergyIntolerance#matching_key (rxnorm vs name).
      def wire_allergy(ien:, allergen:, allergen_code: nil)
        AllergyIntolerance.new(
          ien: ien,
          patient_dfn: DFN,
          allergen: allergen,
          allergen_code: allergen_code,
          clinical_status: "active"
        )
      end

      test "same ien coded supplemental mirror of uncoded wire row same name does not drop" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin")
        mirror = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ mirror ], wire_rows: [ wire ])

        assert_equal 0, reading.dropped_count,
                     "uncoded ORQQAL row and coded supplemental mirror with same name share ien 5"
      end

      test "same ien coded supplemental mirror matches wire name case and whitespace" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin")
        mirror = wire_allergy(ien: "5", allergen: "penicillin ", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ mirror ], wire_rows: [ wire ])

        assert_equal 0, reading.dropped_count,
                     "name comparison under (b) must ignore case and extra whitespace"
      end

      test "same ien both coded different codes same display name counts as dropped" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")
        other_code = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "1234")

        reading = allergy_reading_for_patient(DFN, [ other_code ], wire_rows: [ wire ])

        assert reading.dropped_count >= 1,
               "conflicting rxnorm codes on one ien must not read as one allergy"
      end

      test "same ien coded vs uncoded different names counts as dropped" do
        wire = wire_allergy(ien: "5", allergen: "Latex")
        coded = wire_allergy(ien: "5", allergen: "Peanut", allergen_code: "891658")

        reading = allergy_reading_for_patient(DFN, [ coded ], wire_rows: [ wire ])

        assert reading.dropped_count >= 1,
               "Latex and Peanut on one ien must count as a list hole"
      end

      test "same ien both coded same code different name text does not drop" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin G", allergen_code: "7980")
        alias_row = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ alias_row ], wire_rows: [ wire ])

        assert_equal 0, reading.dropped_count,
                     "matching rxnorm on one ien is one allergy despite label variation"
      end
    end
  end
end
