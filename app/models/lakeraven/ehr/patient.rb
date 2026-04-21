# frozen_string_literal: true

module Lakeraven
  module EHR
    # Patient model — ActiveModel-based, backed by RPMS via PatientGateway.
    #
    # Faithful port from rpms_redux Patient. All data flows through RPC;
    # no database tables.
    class Patient
      include ActiveModel::Model
      include ActiveModel::Attributes

      # RPMS/VistA core demographics
      attribute :dfn, :integer
      attribute :name, :string
      attribute :ssn, :string
      attribute :dob, :date
      attribute :sex, :string
      attribute :age, :integer
      attribute :race, :string
      attribute :address_line1, :string
      attribute :city, :string
      attribute :state, :string
      attribute :zip_code, :string
      attribute :phone, :string

      # Derived name parts
      attribute :first_name, :string
      attribute :last_name, :string

      # IHS/PRC fields
      attribute :tribal_affiliation, :string
      attribute :tribal_enrollment_number, :string
      attribute :service_area, :string
      attribute :coverage_type, :string

      # -- Class methods (AR-like) -------------------------------------------

      def self.find_by_dfn(dfn)
        return nil unless dfn.present? && dfn.to_i > 0
        PatientGateway.find(dfn.to_i)
      end

      def self.search(name_pattern)
        PatientGateway.search(name_pattern.to_s)
      end

      def self.find_by_ssn(ssn)
        return nil if ssn.blank?
        PatientGateway.find_by_ssn(ssn.to_s)
      end

      # -- Initialize with composite field sync ------------------------------

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

      def formal_name
        return name if name.blank?
        parts = name.split(",")
        if parts.length >= 2
          last = parts[0]&.strip&.split&.map(&:capitalize)&.join(" ")
          first = parts[1]&.strip&.split&.map(&:capitalize)&.join(" ")
          "#{last}, #{first}"
        else
          name.split.map(&:capitalize).join(" ")
        end
      end

      def to_param
        dfn.to_s
      end

      # -- FHIR serialization -----------------------------------------------

      def to_fhir
        FHIR::PatientSerializer.call(self)
      end

      private

      def sync_composite_fields
        if first_name.present? && last_name.present? && name.blank?
          self.name = "#{last_name},#{first_name}"
        end

        if name.present? && first_name.blank? && last_name.blank?
          parts = name.split(",")
          self.last_name = parts[0]&.strip&.capitalize
          self.first_name = parts[1]&.strip&.capitalize if parts.length > 1
        end
      end
    end
  end
end
