# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class VfcEligibilityTest < ActiveSupport::TestCase
      test "patient_eligibility returns code and label" do
        result = VfcEligibility.patient_eligibility("1")
        assert_kind_of Hash, result
        assert result.key?(:code)
        assert result.key?(:label)
      end

      test "patient_eligibility returns nil code for unknown patient" do
        result = VfcEligibility.patient_eligibility("99999")
        assert_nil result[:code]
      end

      test "list_codes returns array of code/label hashes" do
        codes = VfcEligibility.list_codes
        assert_kind_of Array, codes
      end

      test "eligible? checks VFC eligible codes" do
        assert VfcEligibility.eligible?("V02")
        assert VfcEligibility.eligible?("V04")
        assert_not VfcEligibility.eligible?("V01")
        assert_not VfcEligibility.eligible?(nil)
      end
    end
  end
end
