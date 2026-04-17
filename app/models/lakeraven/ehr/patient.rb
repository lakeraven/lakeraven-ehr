# frozen_string_literal: true

module Lakeraven
  module EHR
    # Clinical patient identity model. ActiveModel-based (no database) —
    # demographics flow through the configured adapter at request time.
    #
    # This is the canonical Patient for lakeraven-ehr host apps. It provides:
    # - RPMS/VistA attribute set (DFN, name in LAST,FIRST format, etc.)
    # - Composite field syncing (name ↔ first_name/last_name, dob ↔ born_on)
    # - FHIR R4 serialization via FHIR::PatientSerializer
    # - FHIR R4 deserialization via FHIR::PatientDeserializer
    # - US Core race/ethnicity + IHS tribal + SOGI extensions
    #
    # Host apps subclass this to wire gateway persistence and
    # host-specific behavior.
    class Patient
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      # Opaque identifier per ADR 0004. Set by the adapter; not derived
      # from dfn or any backend-native key.
      attribute :patient_identifier, :string

      # RPMS/VistA core demographics
      attribute :dfn, :integer
      attribute :name, :string
      attribute :ssn, :string
      attribute :dob, :date
      attribute :sex, :string
      attribute :gender, :string
      attribute :age, :integer
      attribute :race, :string
      attribute :address, :string
      attribute :address_line1, :string
      attribute :city, :string
      attribute :state, :string
      attribute :zip_code, :string
      attribute :phone, :string

      # Derived name parts (synced with name)
      attribute :first_name, :string
      attribute :last_name, :string
      attribute :born_on, :date
      attribute :birth_date, :date

      # IHS/PRC fields
      attribute :tribal_affiliation, :string
      attribute :tribal_enrollment_number, :string
      attribute :service_area, :string
      attribute :coverage_type, :string

      # SOGI (USCDI v3 / ONC §170.315(a)(15))
      attribute :sexual_orientation, :string
      attribute :gender_identity, :string

      validates :sex, inclusion: { in: %w[M F U] }, allow_nil: true

      def initialize(attributes = {})
        super
        sync_composite_fields
      end

      # ----------------------------------------------------------------
      # Composite field syncing
      # ----------------------------------------------------------------

      def sync_composite_fields
        self.born_on ||= dob
        self.dob ||= born_on

        if first_name.present? && last_name.present? && name.blank?
          self.name = "#{last_name},#{first_name}"
        end

        if name.present? && first_name.blank? && last_name.blank?
          pn = patient_name
          self.last_name = pn.last_name
          self.first_name = pn.first_name
        end
      end

      # ----------------------------------------------------------------
      # Name formatting (delegates to PatientName value object)
      # ----------------------------------------------------------------

      def patient_name
        PatientName.new(name: name, first_name: first_name, last_name: last_name)
      end

      def display_name
        patient_name.display
      end

      def formal_name
        patient_name.formal
      end

      # ----------------------------------------------------------------
      # FHIR serialization
      # ----------------------------------------------------------------

      def to_fhir
        FHIR::PatientSerializer.call(to_serializer_hash)
      end

      def self.from_fhir(fhir_resource)
        new(**FHIR::PatientDeserializer.call(fhir_resource))
      end

      def to_param
        patient_identifier || dfn.to_s
      end

      private

      def to_serializer_hash
        {
          patient_identifier: patient_identifier || dfn&.to_s,
          display_name: name,
          date_of_birth: dob || birth_date,
          gender: gender || sex,
          dfn: dfn,
          ssn: ssn,
          address_line1: address_line1 || address,
          city: city,
          state: state,
          zip_code: zip_code,
          phone: phone,
          race: race,
          tribal_affiliation: tribal_affiliation,
          tribal_enrollment_number: tribal_enrollment_number,
          sexual_orientation: sexual_orientation,
          gender_identity: gender_identity,
          identifiers: []
        }
      end
    end
  end
end
