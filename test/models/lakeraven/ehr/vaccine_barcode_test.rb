# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class VaccineBarcodeTest < ActiveSupport::TestCase
      # ======================================================================
      # GS1-128 PARSING
      # ======================================================================

      test "parses GS1-128 barcode with all AIs" do
        barcode = "011234567890123417260310101234A\x1D21SN98765"
        result = VaccineBarcode.parse(barcode)

        assert result.valid?
        assert_equal "1234A", result.lot_number
        assert_equal Date.new(2026, 3, 10), result.expiration_date
        assert_equal "SN98765", result.serial_number
      end

      test "parses barcode with FNC1 separators" do
        barcode = "0100364141234561172603101012345\x1D21SN98765"
        result = VaccineBarcode.parse(barcode)

        assert result.valid?
        assert_equal "12345", result.lot_number
        assert_equal "SN98765", result.serial_number
      end

      test "parses barcode with only GTIN and lot" do
        barcode = "01003641412345611012345"
        result = VaccineBarcode.parse(barcode)

        assert result.valid?
        assert_equal "12345", result.lot_number
        assert_nil result.expiration_date
        assert_nil result.serial_number
      end

      test "parses barcode with only GTIN and expiration" do
        barcode = "010036414123456117260310"
        result = VaccineBarcode.parse(barcode)

        assert result.valid?
        assert_equal Date.new(2026, 3, 10), result.expiration_date
        assert_nil result.lot_number
      end

      # ======================================================================
      # SCANNER FORMAT NORMALIZATION
      # ======================================================================

      test "parses DataMatrix with ]d2 AIM prefix" do
        barcode = "]d20100364141234561172603101012345"
        result = VaccineBarcode.parse(barcode)

        assert result.valid?
        assert_equal "00364141234561", result.gtin
        assert_equal "12345", result.lot_number
        assert_equal Date.new(2026, 3, 10), result.expiration_date
      end

      test "parses GS1-128 with ]C1 AIM prefix" do
        barcode = "]C10100364141234561172603101012345"
        result = VaccineBarcode.parse(barcode)

        assert result.valid?
        assert_equal "00364141234561", result.gtin
      end

      test "parses human-readable format with parenthesized AIs" do
        barcode = "(01)00364141234561(17)260310(10)12345"
        result = VaccineBarcode.parse(barcode)

        assert result.valid?
        assert_equal "00364141234561", result.gtin
        assert_equal Date.new(2026, 3, 10), result.expiration_date
        assert_equal "12345", result.lot_number
      end

      # ======================================================================
      # NDC EXTRACTION FROM GTIN-14
      # ======================================================================

      test "ndc_candidate extracts raw 10-digit NDC from GTIN-14" do
        barcode = "0100364141234561172603101012345"
        result = VaccineBarcode.parse(barcode)

        assert_equal "3641412345", result.ndc_candidate
      end

      test "ndc_code is aliased to ndc_candidate" do
        barcode = "0100364141234561172603101012345"
        result = VaccineBarcode.parse(barcode)

        assert_equal result.ndc_candidate, result.ndc_code
      end

      test "ndc_candidate returns 10-digit string without dashes" do
        barcode = "0100349281015024172603101012345"
        result = VaccineBarcode.parse(barcode)

        assert result.ndc_candidate.present?
        assert_equal 10, result.ndc_candidate.length
        assert_match(/\A\d{10}\z/, result.ndc_candidate)
      end

      test "ndc_candidate returns nil for invalid barcode" do
        result = VaccineBarcode.parse("not a barcode")
        assert_nil result.ndc_candidate
      end

      # ======================================================================
      # EXPIRATION DATE EDGE CASES
      # ======================================================================

      test "handles YYMMDD with day 00 as end of month" do
        barcode = "0100364141234561172603001012345"
        result = VaccineBarcode.parse(barcode)

        assert_equal Date.new(2026, 3, 31), result.expiration_date
      end

      test "handles February end-of-month in leap year" do
        barcode = "0100364141234561172802001012345"
        result = VaccineBarcode.parse(barcode)

        assert_equal Date.new(2028, 2, 29), result.expiration_date
      end

      test "handles February end-of-month in non-leap year" do
        barcode = "0100364141234561172702001012345"
        result = VaccineBarcode.parse(barcode)

        assert_equal Date.new(2027, 2, 28), result.expiration_date
      end

      # ======================================================================
      # INVALID INPUT
      # ======================================================================

      test "returns invalid result for nil input" do
        result = VaccineBarcode.parse(nil)
        assert_not result.valid?
      end

      test "returns invalid result for empty string" do
        result = VaccineBarcode.parse("")
        assert_not result.valid?
      end

      test "returns invalid result for non-barcode string" do
        result = VaccineBarcode.parse("not a barcode")
        assert_not result.valid?
      end

      test "returns invalid result for barcode without GTIN" do
        result = VaccineBarcode.parse("1012345")
        assert_not result.valid?
      end

      # ======================================================================
      # GTIN ACCESSOR
      # ======================================================================

      test "gtin returns the full 14-digit GTIN" do
        barcode = "0100364141234561172603101012345"
        result = VaccineBarcode.parse(barcode)

        assert_equal "00364141234561", result.gtin
      end

      # ======================================================================
      # ATTRIBUTES
      # ======================================================================

      test "exposes all parsed attributes" do
        barcode = "0100364141234561172603101012345\x1D21SN98765"
        result = VaccineBarcode.parse(barcode)

        assert_respond_to result, :gtin
        assert_respond_to result, :ndc_code
        assert_respond_to result, :lot_number
        assert_respond_to result, :expiration_date
        assert_respond_to result, :serial_number
        assert_respond_to result, :valid?
      end
    end
  end
end
