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

      # -- Clinical data accessors (ported from rpms_redux) ------------------

      def service_requests
        return [] unless dfn

        ServiceRequest.for_patient(dfn)
      end

      def allergies
        return [] unless dfn

        AllergyIntolerance.for_patient(dfn)
      end

      def problem_list
        return [] unless dfn

        Condition.for_patient(dfn)
      end

      def medications
        return [] unless dfn

        MedicationRequest.for_patient(dfn)
      end

      def vitals
        return [] unless dfn

        Observation.for_patient(dfn)
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

      # -- Providers (ported from rpms_redux) ----------------------------------

      def providers
        all_srs = service_requests || []
        provider_iens = (all_srs.map(&:requesting_provider_ien) +
                         all_srs.map { |sr| sr.respond_to?(:referred_provider_ien) ? sr.referred_provider_ien : nil })
                        .compact.uniq.select(&:positive?)
        provider_iens.filter_map { |ien| Practitioner.find_by_ien(ien) }
      end

      # -- FHIR serialization -----------------------------------------------

      def to_fhir
        FHIR::PatientSerializer.call(self)
      end

      # -- FHIR deserialization (ported from rpms_redux) ---------------------

      def self.from_fhir_attributes(fhir_resource)
        gender_code = map_fhir_gender_to_sex(fhir_resource.gender)
        {
          name: extract_name_from_fhir(fhir_resource),
          dob: fhir_resource.birthDate ? Date.parse(fhir_resource.birthDate) : nil,
          sex: gender_code,
          ssn: extract_ssn_from_fhir(fhir_resource)
        }
      end

      def self.extract_name_from_fhir(fhir_resource)
        return nil unless fhir_resource.name&.any?
        name_obj = fhir_resource.name.first
        return name_obj.text if name_obj.respond_to?(:text) && name_obj.text.present?
        family = name_obj.family
        given = name_obj.given&.join(" ")
        given.present? ? "#{family},#{given}" : family
      end

      def self.map_fhir_gender_to_sex(gender)
        case gender&.downcase
        when "male" then "M"
        when "female" then "F"
        else "U"
        end
      end

      def self.extract_ssn_from_fhir(fhir_resource)
        return nil unless fhir_resource.identifier&.any?
        ssn_id = fhir_resource.identifier.find { |id| id.system&.include?("ssn") }
        ssn_id&.value
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
