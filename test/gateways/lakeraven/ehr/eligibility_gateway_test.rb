# frozen_string_literal: true

require "test_helper"

# Tests for EligibilityGateway — VFC eligibility via BIPC ELIGGET / BIPC ELIGLIST.
# Uses mock data seeded in test_helper.rb via RpmsRpc.mock!
module Lakeraven
  module EHR
    class EligibilityGatewayTest < ActiveSupport::TestCase
      # === patient_eligibility ===

      test "patient_eligibility returns hash with code and label" do
        result = EligibilityGateway.patient_eligibility("1")

        assert_kind_of Hash, result
        assert result.key?(:code), "Should have :code key"
        assert result.key?(:label), "Should have :label key"
      end

      test "patient_eligibility returns seeded VFC code for patient 1" do
        result = EligibilityGateway.patient_eligibility("1")

        assert_equal "V04", result[:code]
        assert_equal "American Indian/Alaska Native", result[:label]
      end

      test "patient_eligibility returns nil code for unknown patient" do
        result = EligibilityGateway.patient_eligibility("999999")

        assert_nil result[:code], "Should return nil code for unknown patient"
      end

      # === list_codes ===

      test "list_codes returns array of hashes" do
        codes = EligibilityGateway.list_codes

        assert_kind_of Array, codes
        assert codes.length > 0, "Should return seeded VFC codes"
      end

      test "list_codes returns all seeded VFC codes" do
        codes = EligibilityGateway.list_codes

        assert_equal 7, codes.length, "Should return all 7 seeded VFC codes"
      end

      test "list_codes entries have code and label keys" do
        codes = EligibilityGateway.list_codes

        codes.each do |entry|
          assert_kind_of Hash, entry
          assert entry.key?(:code), "Entry should have :code"
          assert entry.key?(:label), "Entry should have :label"
        end
      end

      test "list_codes includes expected codes" do
        codes = EligibilityGateway.list_codes
        code_values = codes.map { |c| c[:code] }

        assert_includes code_values, "V01"
        assert_includes code_values, "V04"
        assert_includes code_values, "V07"
      end

      test "list_codes first entry is V01" do
        codes = EligibilityGateway.list_codes

        assert_equal "V01", codes.first[:code]
        assert_equal "Not VFC eligible", codes.first[:label]
      end

      test "list_codes AI/AN entry has correct label" do
        codes = EligibilityGateway.list_codes
        ai_an = codes.find { |c| c[:code] == "V04" }

        assert_not_nil ai_an
        assert_equal "VFC eligible - AI/AN", ai_an[:label]
      end
    end
  end
end
