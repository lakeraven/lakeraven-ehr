# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TerminologyMapperTest < ActiveSupport::TestCase
      # =============================================================================
      # ICD-10 (US Clinical Modification — default)
      # =============================================================================

      test "ICD10 resolves code and display" do
        icd = Terminology::ICD10.new("E11.9")

        assert_equal "E11.9", icd.code
        assert_equal "http://hl7.org/fhir/sid/icd-10-cm", icd.system
        refute_nil icd.display
      end

      test "ICD10 to_coding returns hash with system, code, display" do
        icd = Terminology::ICD10.new("E11.9")
        coding = icd.to_coding

        assert_equal "E11.9", coding[:code]
        assert_equal "http://hl7.org/fhir/sid/icd-10-cm", coding[:system]
        assert coding[:display].is_a?(String)
      end

      test "ICD10 with nil code returns unmapped" do
        icd = Terminology::ICD10.new(nil)

        assert_nil icd.code
        assert_equal :unmapped, icd.status
      end

      test "ICD10 with blank code returns unmapped" do
        icd = Terminology::ICD10.new("")

        assert_equal :unmapped, icd.status
      end

      # =============================================================================
      # ICD-10 VARIANTS (Swedish, Canadian)
      # =============================================================================

      test "ICD10 Swedish Edition uses SE system URI" do
        icd = Terminology::ICD10.new("E11.9", edition: :se)

        assert_equal "E11.9", icd.code
        assert_includes icd.system, "icd-10-se"
      end

      test "ICD10 Canadian Edition uses CA system URI" do
        icd = Terminology::ICD10.new("E11.9", edition: :ca)

        assert_equal "E11.9", icd.code
        assert_includes icd.system, "icd-10-ca"
      end

      test "ICD10 defaults to CM edition" do
        icd = Terminology::ICD10.new("E11.9")

        assert_includes icd.system, "icd-10-cm"
      end

      # =============================================================================
      # LOINC (universal — no editions)
      # =============================================================================

      test "LOINC resolves code" do
        loinc = Terminology::LOINC.new("2339-0")

        assert_equal "2339-0", loinc.code
        assert_equal "http://loinc.org", loinc.system
      end

      test "LOINC to_coding returns hash" do
        loinc = Terminology::LOINC.new("2339-0")
        coding = loinc.to_coding

        assert_equal "2339-0", coding[:code]
        assert_equal "http://loinc.org", coding[:system]
      end

      test "LOINC with nil code returns unmapped" do
        loinc = Terminology::LOINC.new(nil)

        assert_equal :unmapped, loinc.status
      end

      # =============================================================================
      # RXNORM (US)
      # =============================================================================

      test "RxNorm resolves code" do
        rxnorm = Terminology::RxNorm.new("197884")

        assert_equal "197884", rxnorm.code
        assert_equal "http://www.nlm.nih.gov/research/umls/rxnorm", rxnorm.system
      end

      test "RxNorm to_coding returns hash" do
        rxnorm = Terminology::RxNorm.new("197884")
        coding = rxnorm.to_coding

        assert_equal "197884", coding[:code]
        assert_includes coding[:system], "rxnorm"
      end

      # =============================================================================
      # ATC (WHO — Sweden, international)
      # =============================================================================

      test "ATC resolves code" do
        atc = Terminology::ATC.new("C09AA05")

        assert_equal "C09AA05", atc.code
        assert_equal "http://www.whocc.no/atc", atc.system
      end

      test "ATC to_coding returns hash" do
        atc = Terminology::ATC.new("C09AA05")
        coding = atc.to_coding

        assert_equal "C09AA05", coding[:code]
        assert_includes coding[:system], "atc"
      end

      # =============================================================================
      # DIN (Health Canada)
      # =============================================================================

      test "DIN resolves code" do
        din = Terminology::DIN.new("02248057")

        assert_equal "02248057", din.code
        assert_equal "https://health-products.canada.ca/dpd-bdpp", din.system
      end

      # =============================================================================
      # SNOMED CT (multi-edition)
      # =============================================================================

      test "SNOMED resolves code with US edition" do
        snomed = Terminology::SNOMED.new("44054006")

        assert_equal "44054006", snomed.code
        assert_equal "http://snomed.info/sct", snomed.system
      end

      test "SNOMED with nil code returns unmapped" do
        snomed = Terminology::SNOMED.new(nil)

        assert_equal :unmapped, snomed.status
      end

      test "SNOMED to_coding includes edition version when specified" do
        snomed = Terminology::SNOMED.new("44054006", edition: :se)
        coding = snomed.to_coding

        assert_equal "44054006", coding[:code]
        assert_equal "http://snomed.info/sct", coding[:system]
        assert_equal "http://snomed.info/sct/45991000052106", coding[:version]
      end

      # =============================================================================
      # BASE CONTRACT
      # =============================================================================

      test "all terminology mappers respond to code, system, display, to_coding, status" do
        serializers = [
          Terminology::ICD10.new("E11.9"),
          Terminology::LOINC.new("2339-0"),
          Terminology::RxNorm.new("197884"),
          Terminology::ATC.new("C09AA05"),
          Terminology::DIN.new("02248057"),
          Terminology::SNOMED.new("44054006")
        ]

        serializers.each do |d|
          assert_respond_to d, :code
          assert_respond_to d, :system
          assert_respond_to d, :display
          assert_respond_to d, :to_coding
          assert_respond_to d, :status
        end
      end

      test "mapped status for valid codes" do
        icd = Terminology::ICD10.new("E11.9")

        assert_equal :mapped, icd.status
      end
    end
  end
end
