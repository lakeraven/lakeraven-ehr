# frozen_string_literal: true

module Lakeraven
  module EHR
    class Organization
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :integer
      attribute :name, :string
      attribute :station_number, :string
      attribute :address, :string
      attribute :city, :string
      attribute :state, :string
      attribute :zip_code, :string
      attribute :phone, :string

      def self.find_by_ien(ien)
        return nil unless ien.present? && ien.to_i > 0

        attrs = OrganizationGateway.find(ien.to_i)
        attrs ? new(**attrs) : nil
      end

      def to_fhir
        {
          resourceType: "Organization",
          id: ien.to_s,
          name: name,
          identifier: station_number ? [ { system: "http://hl7.org/fhir/sid/us-npi", value: station_number } ] : [],
          address: build_address,
          telecom: phone.present? ? [ { system: "phone", value: phone } ] : []
        }
      end

      def to_param = ien.to_s

      private

      def build_address
        return [] if address.blank?

        [ { line: [ address ], city: city, state: state, postalCode: zip_code, country: "US" }.compact ]
      end
    end
  end
end
