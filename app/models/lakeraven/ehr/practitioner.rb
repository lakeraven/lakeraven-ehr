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

      class RecordNotFound < StandardError; end

      # -- Gateway DI --------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || PractitionerGateway
        end
      end

      # -- Class methods -----------------------------------------------------

      def self.find(ien)
        practitioner = find_by_ien(ien)
        raise RecordNotFound, "Couldn't find Practitioner with 'ien'=#{ien}" unless practitioner

        practitioner
      end

      def self.find_by_ien(ien)
        return nil unless ien.present? && ien.to_i.positive?

        gateway.find(ien.to_i)
      end

      def self.search(name_pattern)
        gateway.search(name_pattern.to_s)
      end

      def self.create(attributes = {})
        new(attributes).tap(&:save)
      end

      def self.create!(attributes = {})
        new(attributes).tap(&:save!)
      end

      # -- Persistence -------------------------------------------------------

      def save
        return false unless valid?

        if persisted?
          true
        else
          result = self.class.gateway.register(persistable_attributes)
          if result[:success]
            self.ien = result[:ien]
            true
          else
            errors.add(:base, result[:error] || "Registration failed")
            false
          end
        end
      end

      def save!
        save || raise(ActiveModel::ValidationError.new(self))
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
        ien.present? && ien.to_i > 0
      end

      def can_prescribe_controlled?
        dea_number.present? && !dea_number.strip.empty?
      end

      def credentials_summary
        [ title, specialty ].compact.reject(&:empty?).join(", ")
      end

      # -- Class methods (FHIR) -----------------------------------------------

      def self.resource_class
        "Practitioner"
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          name: extract_name_from_fhir(fhir_resource),
          npi: extract_npi_from_fhir(fhir_resource),
          specialty: extract_specialty_from_fhir(fhir_resource)
        }
      end

      def self.extract_name_from_fhir(fhir_resource)
        return nil unless fhir_resource.name&.any?

        name_obj = fhir_resource.name.first
        family = name_obj.family
        given = name_obj.given&.join(" ")

        given.present? ? "#{family}, #{given}" : family
      end

      def self.extract_npi_from_fhir(fhir_resource)
        return nil unless fhir_resource.identifier&.any?

        npi_identifier = fhir_resource.identifier.find do |id|
          id.system&.include?("npi")
        end

        npi_identifier&.value
      end

      def self.extract_specialty_from_fhir(fhir_resource)
        return nil unless fhir_resource.qualification&.any?

        fhir_resource.qualification.first&.code&.text
      end

      # -- FHIR serialization -----------------------------------------------

      def to_fhir
        FHIR::PractitionerSerializer.call(self)
      end

      # -- Validations (for save) ----------------------------------------------

      validates :name, presence: true, if: -> { first_name.blank? && last_name.blank? }

      private

      def persistable_attributes
        {
          name: name, first_name: first_name, last_name: last_name,
          npi: npi, dea_number: dea_number, specialty: specialty,
          provider_class: provider_class, title: title,
          service_section: service_section, phone: phone
        }.compact
      end

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
