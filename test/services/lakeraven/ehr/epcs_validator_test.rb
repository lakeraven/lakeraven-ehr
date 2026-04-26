# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EpcsValidatorTest < ActiveSupport::TestCase
      # =========================================================================
      # CONTROLLED SUBSTANCES — REQUIRE EPCS
      # =========================================================================

      test "schedule II requires EPCS" do
        order = build_order("198440", "Alprazolam 0.5mg")

        result = EpcsValidator.validate(order, dea_schedule: "II", prescriber_dea: "AM1234563")

        assert result[:requires_epcs]
        assert result[:requires_two_factor]
        assert result[:requires_identity_proofing]
      end

      test "schedule III requires EPCS" do
        order = build_order("198440", "Testosterone")

        result = EpcsValidator.validate(order, dea_schedule: "III", prescriber_dea: "AM1234563")

        assert result[:requires_epcs]
      end

      test "schedule IV requires EPCS" do
        order = build_order("198440", "Tramadol 50mg")

        result = EpcsValidator.validate(order, dea_schedule: "IV", prescriber_dea: "AM1234563")

        assert result[:requires_epcs]
      end

      test "schedule V requires EPCS" do
        order = build_order("198440", "Lomotil")

        result = EpcsValidator.validate(order, dea_schedule: "V", prescriber_dea: "AM1234563")

        assert result[:requires_epcs]
      end

      # =========================================================================
      # NON-CONTROLLED — NO EPCS REQUIRED
      # =========================================================================

      test "nil schedule does not require EPCS" do
        order = build_order("311364", "Lisinopril 10mg")

        result = EpcsValidator.validate(order, dea_schedule: nil, prescriber_dea: nil)

        refute result[:requires_epcs]
        refute result[:requires_two_factor]
        refute result[:requires_identity_proofing]
      end

      test "non-controlled prescription always has valid DEA" do
        order = build_order("311364", "Lisinopril 10mg")

        result = EpcsValidator.validate(order, dea_schedule: nil, prescriber_dea: nil)

        assert result[:prescriber_dea_valid]
      end

      # =========================================================================
      # DEA VALIDATION
      # =========================================================================

      test "controlled substance with DEA number is valid" do
        order = build_order("198440", "Oxycodone 5mg")

        result = EpcsValidator.validate(order, dea_schedule: "II", prescriber_dea: "AM1234563")

        assert result[:prescriber_dea_valid]
      end

      test "controlled substance without DEA number is invalid" do
        order = build_order("198440", "Oxycodone 5mg")

        result = EpcsValidator.validate(order, dea_schedule: "II", prescriber_dea: nil)

        refute result[:prescriber_dea_valid]
      end

      # =========================================================================
      # MEDICATION INFO PASSTHROUGH
      # =========================================================================

      test "result includes medication code and display" do
        order = build_order("311364", "Lisinopril 10mg")

        result = EpcsValidator.validate(order, dea_schedule: nil, prescriber_dea: nil)

        assert_equal "311364", result[:medication_code]
        assert_equal "Lisinopril 10mg", result[:medication_display]
      end

      test "result includes dea_schedule" do
        order = build_order("198440", "Alprazolam")

        result = EpcsValidator.validate(order, dea_schedule: "IV", prescriber_dea: "AM1234563")

        assert_equal "IV", result[:dea_schedule]
      end

      private

      def build_order(code, display)
        order = Object.new
        order.define_singleton_method(:medication_code) { code }
        order.define_singleton_method(:medication_display) { display }
        order
      end
    end
  end
end
