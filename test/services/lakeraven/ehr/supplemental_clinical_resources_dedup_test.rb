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
          def begin_assessment_capture!
            @capture = true
            @mark = nil
          end

          def end_assessment_capture!
            @capture = false
          end

          def for_patient(_dfn)
            rows = []
            @mark = { assessed: true, nka: true, rows: rows } if @capture
            rows
          end

          def take_assessment(rows)
            return unless @mark && @mark[:rows].equal?(rows)

            { assessed: @mark[:assessed], nka: @mark[:nka] }
          end
        end
      end

      def with_nka_wire_gateway
        original = AllergyIntolerance.gateway
        AllergyIntolerance.gateway = NkaWireGateway
        yield
      ensure
        AllergyIntolerance.gateway = original
      end

      def allergy_reading_for_patient(dfn, supplemental_rows)
        with_nka_wire_gateway do
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
    end
  end
end
