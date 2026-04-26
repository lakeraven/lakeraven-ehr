# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class UdiParserTest < ActiveSupport::TestCase
      # =============================================================================
      # GS1 UDI PARSING — ONC § 170.315(a)(14)
      # =============================================================================

      test "parses device identifier (01) from GS1 UDI" do
        result = UdiParser.parse("(01)00844588003288(17)141120(10)7654321D(21)10987654d432")

        assert_equal "00844588003288", result[:device_identifier]
      end

      test "parses expiration date (17) from GS1 UDI" do
        result = UdiParser.parse("(01)00844588003288(17)141120")

        assert_equal Date.new(2014, 11, 20), result[:expiration_date]
      end

      test "parses lot number (10) from GS1 UDI" do
        result = UdiParser.parse("(01)00844588003288(10)7654321D")

        assert_equal "7654321D", result[:lot_number]
      end

      test "parses serial number (21) from GS1 UDI" do
        result = UdiParser.parse("(01)00844588003288(21)10987654d432")

        assert_equal "10987654d432", result[:serial_number]
      end

      test "parses manufacturing date (11) from GS1 UDI" do
        result = UdiParser.parse("(01)00844588003288(11)191015")

        assert_equal Date.new(2019, 10, 15), result[:manufacture_date]
      end

      test "parses all components from complete GS1 UDI" do
        udi = "(01)00844588003288(11)240115(17)340115(10)LOTA(21)SER001"
        result = UdiParser.parse(udi)

        assert_equal "00844588003288", result[:device_identifier]
        assert_equal Date.new(2024, 1, 15), result[:manufacture_date]
        assert_equal Date.new(2034, 1, 15), result[:expiration_date]
        assert_equal "LOTA", result[:lot_number]
        assert_equal "SER001", result[:serial_number]
      end

      test "returns nil for missing components" do
        result = UdiParser.parse("(01)00844588003288")

        assert_equal "00844588003288", result[:device_identifier]
        assert_nil result[:expiration_date]
        assert_nil result[:lot_number]
        assert_nil result[:serial_number]
        assert_nil result[:manufacture_date]
      end

      test "returns empty hash for blank input" do
        assert_equal({}, UdiParser.parse(""))
        assert_equal({}, UdiParser.parse(nil))
      end

      test "returns empty hash for non-GS1 format" do
        result = UdiParser.parse("not-a-udi-string")
        assert_equal({}, result)
      end

      test "preserves original HRF string" do
        udi = "(01)00844588003288(17)141120"
        result = UdiParser.parse(udi)

        assert_equal udi, result[:carrier_hrf]
      end

      test "parses HIBCC format with plus prefix" do
        result = UdiParser.parse("+H123456789012(17)141120")

        assert result[:carrier_hrf].present?
      end

      # =============================================================================
      # DEVICE MODEL INTEGRATION
      # =============================================================================

      test "Device.parse_udi! populates components from UDI string" do
        device = Device.new(
          ien: "1", patient_dfn: "456", device_name: "Pacemaker",
          udi_carrier: "(01)00844588003288(17)341015(10)LOT99(21)SER99"
        )

        device.parse_udi!

        assert_equal "00844588003288", device.udi_device_identifier
        assert_equal Date.new(2034, 10, 15), device.expiration_date
        assert_equal "LOT99", device.lot_number
        assert_equal "SER99", device.serial_number
      end

      test "Device.parse_udi! does not overwrite existing values" do
        device = Device.new(
          ien: "1", patient_dfn: "456", device_name: "Pacemaker",
          udi_carrier: "(01)00844588003288(10)LOT99",
          lot_number: "EXISTING_LOT"
        )

        device.parse_udi!

        assert_equal "EXISTING_LOT", device.lot_number
        assert_equal "00844588003288", device.udi_device_identifier
      end
    end
  end
end
