# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class Icd10CmSubstanceUseRangeTest < ActiveSupport::TestCase
      test "F11.20 in the ICD-10-CM system is substance use" do
        problem = {
          code: "F11.20",
          display: "Opioid dependence",
          code_system: "http://hl7.org/fhir/sid/icd-10-cm"
        }

        assert_equal :sud, Icd10CmSubstanceUseRange.classify(problem)
      end

      test "the substance-use range is F10 through F19, not every F code" do
        assert_equal :sud, Icd10CmSubstanceUseRange.classify({ icd_code: "F10" })
        assert_equal :sud, Icd10CmSubstanceUseRange.classify({ icd_code: "F19.21" })
        assert_equal :not_sud, Icd10CmSubstanceUseRange.classify({ icd_code: "F32.1" })
        assert_equal :not_sud, Icd10CmSubstanceUseRange.classify({ icd_code: "F20.0" })
        assert_equal :not_sud, Icd10CmSubstanceUseRange.classify({ icd_code: "E11.9" })
      end

      test "a lowercase code in the range still classifies" do
        assert_equal :sud, Icd10CmSubstanceUseRange.classify({ code: "f11.20", code_system: "icd10" })
      end

      test "a non-ICD-10 system is unclassified even when the code looks like F11.20" do
        problem = { code: "F11.20", code_system: "http://snomed.info/sct" }

        assert_equal :unclassified, Icd10CmSubstanceUseRange.classify(problem)
      end

      test "a missing code is unclassified" do
        assert_equal :unclassified, Icd10CmSubstanceUseRange.classify({ display: "Opioid dependence" })
        assert_equal :unclassified, Icd10CmSubstanceUseRange.classify(nil)
      end
    end
  end
end
