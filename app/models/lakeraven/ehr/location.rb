# frozen_string_literal: true

module Lakeraven
  module EHR
    class Location
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      # Location type codes
      TYPES = {
        "site" => "Site",
        "building" => "Building",
        "wing" => "Wing",
        "room" => "Room",
        "vehicle" => "Vehicle"
      }.freeze

      # Physical type codes (FHIR location-physical-type)
      PHYSICAL_TYPES = {
        "si" => "Site",
        "bu" => "Building",
        "wi" => "Wing",
        "wa" => "Ward",
        "lvl" => "Level",
        "co" => "Corridor",
        "ro" => "Room",
        "bd" => "Bed",
        "ve" => "Vehicle",
        "ho" => "House",
        "ca" => "Cabinet",
        "rd" => "Road",
        "area" => "Area",
        "jdn" => "Jurisdiction"
      }.freeze

      # Status values (FHIR location-status)
      STATUSES = %w[active suspended inactive].freeze

      attribute :ien, :integer
      attribute :name, :string
      attribute :abbreviation, :string
      attribute :type, :string
      attribute :division, :string
      attribute :location_type, :string
      attribute :status, :string, default: "active"
      attribute :managing_organization_ien, :integer
      attribute :address_line1, :string
      attribute :city, :string
      attribute :state, :string
      attribute :zip_code, :string
      attribute :phone, :string
      attribute :physical_type, :string

      # Validations
      validates :name, presence: true
      validates :location_type, inclusion: { in: TYPES.keys }, allow_blank: true
      validates :status, inclusion: { in: STATUSES }, allow_blank: true
      validates :physical_type, inclusion: { in: PHYSICAL_TYPES.keys }, allow_blank: true
      validate :ien_valid_if_present

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || LocationGateway
        end
      end

      def self.find_by_ien(ien)
        return nil unless ien.present? && ien.to_i > 0

        attrs = gateway.find(ien.to_i)
        attrs ? new(**attrs) : nil
      end

      # =============================================================================
      # STATUS HELPERS
      # =============================================================================

      def active?
        status == "active"
      end

      def suspended?
        status == "suspended"
      end

      def inactive?
        status == "inactive"
      end

      def available_for_scheduling?
        active?
      end

      # =============================================================================
      # TYPE HELPERS
      # =============================================================================

      def type_display
        TYPES[location_type] || "Unknown"
      end

      def physical_type_display
        PHYSICAL_TYPES[physical_type] || "Unknown"
      end

      # =============================================================================
      # ADDRESS HELPERS
      # =============================================================================

      def full_address
        parts = [ address_line1, city, state, zip_code ].compact.reject(&:blank?)
        parts.join(", ")
      end

      # =============================================================================
      # FHIR SERIALIZATION
      # =============================================================================

      def to_fhir
        {
          resourceType: "Location",
          id: ien.to_s,
          name: name,
          status: status,
          mode: "instance",
          alias: abbreviation.present? ? [ abbreviation ] : [],
          identifier: build_fhir_identifiers,
          type: build_fhir_type,
          physicalType: build_fhir_physical_type,
          address: build_fhir_address,
          telecom: build_fhir_telecom,
          managingOrganization: build_fhir_managing_organization
        }.compact
      end

      def self.resource_class
        "Location"
      end

      def self.from_fhir(fhir_resource)
        attrs = from_fhir_attributes(fhir_resource)
        new(attrs)
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          name: fhir_resource.name,
          status: fhir_resource.status || "active",
          location_type: extract_type_from_fhir(fhir_resource),
          physical_type: extract_physical_type_from_fhir(fhir_resource),
          managing_organization_ien: extract_org_ien_from_fhir(fhir_resource)
        }
      end

      def to_param = ien.to_s

      def persisted?
        ien.present? && ien.to_i.positive?
      end

      private

      def ien_valid_if_present
        if ien.present? && ien.to_i <= 0
          errors.add(:ien, "must be greater than 0")
        end
      end

      def build_fhir_identifiers
        return [] unless ien.present?

        [ { use: "usual", system: "http://ihs.gov/rpms/location-id", value: ien.to_s } ]
      end

      def build_fhir_type
        return [] if location_type.blank?

        [ { coding: [ { system: "http://terminology.hl7.org/CodeSystem/location-type",
                         code: location_type, display: type_display } ] } ]
      end

      def build_fhir_physical_type
        return nil if physical_type.blank?

        { coding: [ { system: "http://terminology.hl7.org/CodeSystem/location-physical-type",
                       code: physical_type, display: physical_type_display } ] }
      end

      def build_fhir_address
        return nil if address_line1.blank? && city.blank?

        { use: "work", line: [ address_line1 ].compact, city: city,
          state: state, postalCode: zip_code, country: "US" }.compact
      end

      def build_fhir_telecom
        return [] unless phone.present?

        [ { system: "phone", value: phone, use: "work" } ]
      end

      def build_fhir_managing_organization
        return nil unless managing_organization_ien.present?

        { reference: "Organization/rpms-organization-#{managing_organization_ien}" }
      end

      def self.extract_type_from_fhir(fhir_resource)
        return nil unless fhir_resource.type&.any?

        fhir_resource.type.first.coding&.first&.code
      end

      def self.extract_physical_type_from_fhir(fhir_resource)
        return nil unless fhir_resource.physicalType

        fhir_resource.physicalType.coding&.first&.code
      end

      def self.extract_org_ien_from_fhir(fhir_resource)
        return nil unless fhir_resource.managingOrganization

        ref = fhir_resource.managingOrganization.reference
        return nil unless ref

        if (match = ref.match(/rpms-organization-(\d+)/))
          match[1].to_i
        elsif (match = ref.match(%r{Organization/(\d+)}))
          match[1].to_i
        end
      end
    end
  end
end
