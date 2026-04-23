# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DeviceTest < ActiveSupport::TestCase
      test "has UDI and manufacturer attributes" do
        d = Device.new(
          ien: "1", patient_dfn: "100",
          udi_carrier: "(01)00844588003288(17)141120(10)7654321D(21)10987654d321",
          manufacturer: "Medtronic", device_name: "Cardiac Pacemaker",
          model_number: "PM-2000", serial_number: "SN12345"
        )
        assert_equal "Medtronic", d.manufacturer
        assert_equal "Cardiac Pacemaker", d.device_name
        assert_equal "PM-2000", d.model_number
        assert_equal "SN12345", d.serial_number
      end

      test "defaults status to active" do
        assert_equal "active", Device.new.status
      end

      test "active? for active status" do
        assert Device.new(status: "active").active?
      end

      test "active? false for inactive" do
        refute Device.new(status: "inactive").active?
      end

      test "stores dates" do
        d = Device.new(
          manufacture_date: Date.new(2020, 1, 1),
          expiration_date: Date.new(2030, 12, 31),
          lot_number: "LOT456"
        )
        assert_equal Date.new(2020, 1, 1), d.manufacture_date
        assert_equal Date.new(2030, 12, 31), d.expiration_date
        assert_equal "LOT456", d.lot_number
      end

      test "to_fhir returns Device resource" do
        d = Device.new(ien: "42", patient_dfn: "100", manufacturer: "Medtronic")
        fhir = d.to_fhir
        assert_equal "Device", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "Medtronic", fhir[:manufacturer]
      end

      test "to_fhir includes patient reference" do
        d = Device.new(ien: "1", patient_dfn: "100")
        fhir = d.to_fhir
        assert_equal "Patient/100", fhir.dig(:patient, :reference)
      end

      test "to_fhir includes UDI carrier" do
        d = Device.new(ien: "1", udi_carrier: "(01)00844588003288")
        fhir = d.to_fhir
        assert_equal "(01)00844588003288", fhir[:udiCarrier].first[:carrierHRF]
      end

      test "to_fhir includes device name" do
        d = Device.new(ien: "1", device_name: "Pacemaker")
        fhir = d.to_fhir
        assert_equal "Pacemaker", fhir[:deviceName].first[:name]
      end

      test "to_fhir includes status" do
        d = Device.new(ien: "1", status: "active")
        fhir = d.to_fhir
        assert_equal "active", fhir[:status]
      end
    end
  end
end
