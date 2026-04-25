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

      # -- Validations (ported from rpms_redux) ----------------------------------

      test "validates patient_dfn presence" do
        d = Device.new(device_name: "Pacemaker")
        assert_not d.valid?
        assert_includes d.errors[:patient_dfn], "can't be blank"
      end

      test "validates device_name presence" do
        d = Device.new(patient_dfn: "1")
        assert_not d.valid?
        assert_includes d.errors[:device_name], "can't be blank"
      end

      test "validates status inclusion" do
        d = Device.new(patient_dfn: "1", device_name: "Pacemaker", status: "invalid")
        assert_not d.valid?
        assert_includes d.errors[:status], "is not included in the list"
      end

      test "allows valid status values" do
        %w[active inactive entered-in-error unknown].each do |s|
          d = Device.new(patient_dfn: "1", device_name: "Pacemaker", status: s)
          assert d.valid?, "Expected #{s} to be valid"
        end
      end

      # -- FHIR extras (ported from rpms_redux) ----------------------------------

      test "to_fhir includes manufacturer info" do
        d = Device.new(
          ien: "1", patient_dfn: "100", device_name: "Pacemaker",
          manufacturer: "Medtronic", model_number: "MODEL123",
          serial_number: "SN456789", lot_number: "LOT001"
        )
        fhir = d.to_fhir
        assert_equal "Medtronic", fhir[:manufacturer]
        assert_equal "MODEL123", fhir[:modelNumber]
        assert_equal "SN456789", fhir[:serialNumber]
        assert_equal "LOT001", fhir[:lotNumber]
      end

      test "to_fhir includes dates" do
        d = Device.new(
          ien: "1", patient_dfn: "100", device_name: "Pacemaker",
          manufacture_date: Date.new(2024, 1, 15),
          expiration_date: Date.new(2034, 1, 15)
        )
        fhir = d.to_fhir
        assert_equal "2024-01-15", fhir[:manufactureDate]
        assert_equal "2034-01-15", fhir[:expirationDate]
      end

      test "to_fhir includes type with SNOMED" do
        d = Device.new(
          ien: "1", patient_dfn: "100", device_name: "Pacemaker",
          type_code: "14106009", type_display: "Cardiac pacemaker, device"
        )
        fhir = d.to_fhir
        coding = fhir[:type][:coding].first
        assert_equal "14106009", coding[:code]
        assert_equal "http://snomed.info/sct", coding[:system]
        assert_equal "Cardiac pacemaker, device", coding[:display]
      end

      test "persisted? true when ien present" do
        assert Device.new(ien: "1", patient_dfn: "1", device_name: "Test").persisted?
      end

      test "persisted? false when ien blank" do
        refute Device.new(patient_dfn: "1", device_name: "Test").persisted?
      end
    end
  end
end
