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

      # Date aliases
      attribute :born_on, :date
      attribute :birth_date, :date

      # Derived name parts
      attribute :first_name, :string
      attribute :last_name, :string

      # IHS/PRC fields
      attribute :tribal_affiliation, :string
      attribute :tribal_enrollment_number, :string
      attribute :service_area, :string
      attribute :coverage_type, :string

      class RecordNotFound < StandardError; end

      # -- Class methods (AR-like) -------------------------------------------

      def self.find(dfn)
        patient = find_by_dfn(dfn)
        raise RecordNotFound, "Couldn't find Patient with 'dfn'=#{dfn}" unless patient

        patient
      end

      def self.find_by_dfn(dfn)
        return nil unless dfn.present? && dfn.to_i.positive?

        PatientGateway.find(dfn.to_i)
      end

      def self.search(name_pattern)
        PatientGateway.search(name_pattern.to_s)
      end

      def self.search_by_ssn(ssn)
        patient = find_by_ssn(ssn)
        patient ? [ patient ] : []
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

      def persisted?
        dfn.present? && dfn.to_i.positive?
      end

      # -- Tribal enrollment -------------------------------------------------

      def tribal_enrollment_details
        return nil unless dfn

        TribalEnrollmentGateway.enrollment_details(dfn)
      end

      def validate_tribal_enrollment
        return { valid: false, message: "No enrollment number" } if tribal_enrollment_number.blank?

        TribalEnrollmentGateway.validate(tribal_enrollment_number)
      end

      def tribal_enrollment_valid?
        result = validate_tribal_enrollment
        result && result[:valid] && result[:status] == "ACTIVE"
      end

      def eligible_for_ihs_services?
        return false unless dfn

        result = TribalEnrollmentGateway.eligibility(dfn)
        result[:active] && result[:eligible_for_ihs]
      end

      def enrollment_service_unit
        return nil unless dfn

        TribalEnrollmentGateway.service_unit(dfn)
      end

      def tribe_information
        return nil if tribal_enrollment_number.blank?

        tribe_code = tribal_enrollment_number.split("-").first
        TribalEnrollmentGateway.tribe_info(tribe_code)
      end

      # -- FHIR serialization -----------------------------------------------

      def to_fhir
        FHIR::PatientSerializer.call(self)
      end

      private

      def sync_composite_fields
        # Sync born_on ↔ dob
        self.born_on ||= dob
        self.dob ||= born_on

        # Sync name ↔ first_name/last_name
        self.name = "#{last_name},#{first_name}" if first_name.present? && last_name.present? && name.blank?

        return unless name.present? && first_name.blank? && last_name.blank?

        parts = name.split(",")
        self.last_name = parts[0]&.strip&.capitalize
        self.first_name = parts[1]&.strip&.capitalize if parts.length > 1
      end
    end
  end
end
