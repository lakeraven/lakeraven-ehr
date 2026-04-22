# frozen_string_literal: true

module Lakeraven
  module EHR
    # Practitioner model — ActiveModel-based, backed by RPMS via PractitionerGateway.
    class Practitioner
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :integer
      attribute :name, :string
      attribute :npi, :string
      attribute :dea_number, :string
      attribute :specialty, :string
      attribute :provider_class, :string
      attribute :title, :string
      attribute :service_section, :string
      attribute :phone, :string

      # Derived name parts
      attribute :first_name, :string
      attribute :last_name, :string

      # -- Class methods -----------------------------------------------------

      def self.find_by_ien(ien)
        return nil unless ien.present? && ien.to_i.positive?

        PractitionerGateway.find(ien.to_i)
      end

      def self.search(name_pattern)
        PractitionerGateway.search(name_pattern.to_s)
      end

      # -- Initialize --------------------------------------------------------

      def initialize(attributes = {})
        super
        sync_composite_fields
      end

      # -- Name helpers ------------------------------------------------------

      def display_name
        return name if name.blank?

        parts = name.split(",")
        last = parts[0]&.strip
        first = parts[1]&.strip
        first.present? ? "#{first} #{last}" : last
      end

      def to_param
        ien.to_s
      end

      def persisted?
        ien.present? && ien.to_i.positive?
      end

      def can_prescribe_controlled?
        dea_number.present? && !dea_number.empty?
      end

      def credentials_summary
        [ title, specialty ].compact.reject(&:empty?).join(", ")
      end

      # -- FHIR serialization -----------------------------------------------

      def to_fhir
        FHIR::PractitionerSerializer.call(self)
      end

      private

      def sync_composite_fields
        self.name = "#{last_name},#{first_name}" if first_name.present? && last_name.present? && name.blank?

        return unless name.present? && first_name.blank? && last_name.blank?

        parts = name.split(",")
        self.last_name = parts[0]&.strip&.capitalize
        self.first_name = parts[1]&.strip&.capitalize if parts.length > 1
      end
    end
  end
end
