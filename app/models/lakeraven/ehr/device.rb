# frozen_string_literal: true

module Lakeraven
  module EHR
    class Device
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :udi_carrier, :string
      attribute :udi_device_identifier, :string
      attribute :status, :string, default: "active"
      attribute :manufacturer, :string
      attribute :manufacture_date, :date
      attribute :expiration_date, :date
      attribute :lot_number, :string
      attribute :serial_number, :string
      attribute :device_name, :string
      attribute :model_number, :string
      attribute :type_code, :string
      attribute :type_display, :string

      def active? = status == "active"

      def to_fhir
        {
          resourceType: "Device",
          id: ien,
          patient: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          udiCarrier: udi_carrier ? [ { carrierHRF: udi_carrier } ] : nil,
          status: status,
          manufacturer: manufacturer,
          deviceName: device_name ? [ { name: device_name, type: "user-friendly-name" } ] : nil
        }.compact
      end
    end
  end
end
