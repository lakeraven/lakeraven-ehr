# frozen_string_literal: true

module Lakeraven
  module EHR
    class Location
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :integer
      attribute :name, :string
      attribute :abbreviation, :string
      attribute :type, :string
      attribute :division, :string

      def self.find_by_ien(ien)
        return nil unless ien.present? && ien.to_i > 0

        attrs = LocationGateway.find(ien.to_i)
        attrs ? new(**attrs) : nil
      end

      def to_fhir
        {
          resourceType: "Location",
          id: ien.to_s,
          name: name,
          alias: abbreviation.present? ? [ abbreviation ] : [],
          mode: "instance"
        }
      end

      def to_param = ien.to_s

      def persisted?
        ien.present? && ien.to_i.positive?
      end

      def active?
        true # Default; RPMS locations are active if returned
      end
    end
  end
end
