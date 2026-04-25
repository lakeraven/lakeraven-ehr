# frozen_string_literal: true

module Lakeraven
  module EHR
    class Organization
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      # Organization type codes (aligned with FHIR organization-type ValueSet)
      TYPES = {
        "prov" => "Healthcare Provider",
        "pay" => "Payer",
        "govt" => "Government",
        "ins" => "Insurance Company",
        "edu" => "Educational Institute",
        "reli" => "Religious Institution",
        "cg" => "Community Group",
        "bus" => "Business",
        "other" => "Other"
      }.freeze

      attribute :ien, :integer
      attribute :name, :string
      attribute :station_number, :string
      attribute :org_type, :string
      attribute :npi, :string
      attribute :tax_id, :string
      attribute :active, :boolean, default: true
      attribute :address, :string
      attribute :city, :string
      attribute :state, :string
      attribute :zip_code, :string
      attribute :phone, :string
      attribute :fax, :string
      attribute :email, :string
      attribute :parent_organization_ien, :integer

      # Validations
      validates :name, presence: true
      validates :org_type, inclusion: { in: TYPES.keys }, allow_blank: true
      validates :npi, length: { is: 10 }, allow_blank: true
      validate :ien_valid_if_present

      # =============================================================================
      # FIND
      # =============================================================================

      def self.find_by_ien(ien)
        return nil unless ien.present? && ien.to_i > 0

        attrs = OrganizationGateway.find(ien.to_i)
        attrs ? new(**attrs) : nil
      end

      # =============================================================================
      # TYPE HELPERS
      # =============================================================================

      def type_display
        TYPES[org_type] || "Unknown"
      end

      def provider?
        org_type == "prov"
      end

      def payer?
        org_type == "pay"
      end

      def government?
        org_type == "govt"
      end

      # =============================================================================
      # ADDRESS HELPERS
      # =============================================================================

      def full_address
        [ address, city, state, zip_code ].compact.reject(&:empty?).join(", ")
      end

      # =============================================================================
      # HIERARCHY
      # =============================================================================

      def parent_organization
        return nil unless parent_organization_ien.present?

        @parent_organization ||= self.class.find_by_ien(parent_organization_ien)
      end

      # =============================================================================
      # FHIR SERIALIZATION
      # =============================================================================

      def to_fhir
        {
          resourceType: "Organization",
          id: ien.to_s,
          name: name,
          active: active,
          identifier: build_fhir_identifiers,
          type: build_fhir_type,
          address: build_fhir_address,
          telecom: build_fhir_telecom,
          partOf: build_fhir_part_of
        }.compact
      end

      def self.resource_class
        "Organization"
      end

      def self.from_fhir(fhir_resource)
        attrs = from_fhir_attributes(fhir_resource)
        new(attrs)
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          name: fhir_resource.name,
          npi: extract_npi_from_fhir(fhir_resource),
          org_type: extract_type_from_fhir(fhir_resource),
          active: fhir_resource.active.nil? ? true : fhir_resource.active
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
        identifiers = []

        # IEN / RPMS identifier
        if ien.present?
          identifiers << { use: "usual", system: "http://ihs.gov/rpms/organization-id", value: ien.to_s }
        end

        # Station number
        if station_number.present?
          identifiers << { system: "http://hl7.org/fhir/sid/us-npi", value: station_number }
        end

        # NPI identifier
        if npi.present?
          identifiers << { use: "official", system: "http://hl7.org/fhir/sid/us-npi", value: npi }
        end

        # Tax ID identifier
        if tax_id.present?
          identifiers << { use: "official", system: "urn:oid:2.16.840.1.113883.4.4", value: tax_id }
        end

        identifiers
      end

      def build_fhir_type
        return [] if org_type.blank?

        [ {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/organization-type",
            code: org_type,
            display: type_display
          } ]
        } ]
      end

      def build_fhir_address
        return [] if address.blank? && city.blank?

        [ { line: [ address ].compact, city: city, state: state, postalCode: zip_code, country: "US" }.compact ]
      end

      def build_fhir_telecom
        telecom = []
        telecom << { system: "phone", value: phone, use: "work" } if phone.present?
        telecom << { system: "fax", value: fax, use: "work" } if fax.present?
        telecom << { system: "email", value: email, use: "work" } if email.present?
        telecom
      end

      def build_fhir_part_of
        return nil unless parent_organization_ien.present?

        { reference: "Organization/#{parent_organization_ien}" }
      end

      def self.extract_npi_from_fhir(fhir_resource)
        return nil unless fhir_resource.identifier&.any?

        npi_id = fhir_resource.identifier.find { |id| id.system&.include?("npi") }
        npi_id&.value
      end

      def self.extract_type_from_fhir(fhir_resource)
        return nil unless fhir_resource.type&.any?

        type = fhir_resource.type.first
        coding = type.coding&.first
        coding&.code
      end
    end
  end
end
