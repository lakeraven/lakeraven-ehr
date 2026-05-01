# frozen_string_literal: true

module Lakeraven
  module EHR
    class Device
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_STATUSES = %w[active inactive entered-in-error unknown].freeze

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
      attribute :distinct_identifier, :string

      validates :patient_dfn, presence: true
      validates :device_name, presence: true
      validates :status, inclusion: { in: VALID_STATUSES }

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || DeviceGateway
        end
      end

      def self.for_patient(dfn, **_opts)
        gateway.for_patient(dfn)
      rescue NameError
        # DeviceGateway not yet implemented
        []
      end

      def active? = status == "active"
      def persisted? = ien.present?

      # Parse UDI carrier string and populate device fields.
      # Does not overwrite existing values. ONC § 170.315(a)(14).
      def parse_udi!
        return unless udi_carrier.present?

        parsed = UdiParser.parse(udi_carrier)
        return if parsed.empty?

        self.udi_device_identifier ||= parsed[:device_identifier]
        self.expiration_date       ||= parsed[:expiration_date]
        self.lot_number            ||= parsed[:lot_number]
        self.serial_number         ||= parsed[:serial_number]
        self.manufacture_date      ||= parsed[:manufacture_date]
      end

      def to_fhir
        {
          resourceType: "Device",
          id: ien,
          meta: build_meta,
          patient: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          udiCarrier: udi_carrier ? [ { carrierHRF: udi_carrier, deviceIdentifier: udi_device_identifier }.compact ] : nil,
          status: status,
          manufacturer: manufacturer,
          modelNumber: model_number,
          serialNumber: serial_number,
          lotNumber: lot_number,
          manufactureDate: manufacture_date&.iso8601,
          expirationDate: expiration_date&.iso8601,
          distinctIdentifier: distinct_identifier,
          type: build_type,
          deviceName: device_name ? [ { name: device_name, type: "user-friendly-name" } ] : nil
        }.compact
      end

      private

      def build_meta
        {
          profile: [ "http://hl7.org/fhir/us/core/StructureDefinition/us-core-implantable-device" ]
        }
      end

      def build_type
        return nil unless type_code

        { coding: [ { code: type_code, system: "http://snomed.info/sct", display: type_display }.compact ] }
      end
    end
  end
end
