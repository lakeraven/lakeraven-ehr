# frozen_string_literal: true

module Lakeraven
  module EHR
    # Clinical practitioner identity model. ActiveModel-based (no database) —
    # provider data flows through the configured adapter at request time.
    #
    # This is the canonical Practitioner for lakeraven-ehr host apps. It provides:
    # - RPMS/VistA attribute set (IEN, name in LAST,FIRST format, NPI, etc.)
    # - Composite field syncing (name ↔ first_name/last_name)
    # - FHIR R4 serialization via FHIR::PractitionerSerializer
    # - FHIR R4 deserialization via FHIR::PractitionerDeserializer
    # - US Core Practitioner profile conformance
    #
    # Host apps subclass this to wire gateway persistence and
    # host-specific behavior.
    class Practitioner
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      # Opaque identifier per ADR 0004. Set by the adapter; not derived
      # from ien or any backend-native key.
      attribute :practitioner_identifier, :string

      # RPMS/VistA core demographics
      attribute :ien, :integer
      attribute :name, :string
      attribute :npi, :string
      attribute :dea_number, :string
      attribute :gender, :string
      attribute :specialty, :string
      attribute :provider_class, :string
      attribute :title, :string
      attribute :service_section, :string
      attribute :phone, :string

      # Derived name parts (synced with name)
      attribute :first_name, :string
      attribute :last_name, :string

      validates :npi, format: { with: /\A\d{10}\z/, message: "must be 10 digits" },
                      allow_nil: true, allow_blank: true

      def initialize(attributes = {})
        super
        sync_composite_fields
      end

      # ----------------------------------------------------------------
      # Composite field syncing
      # ----------------------------------------------------------------

      def sync_composite_fields
        if first_name.present? && last_name.present? && name.blank?
          self.name = "#{last_name},#{first_name}"
        end

        if name.present? && first_name.blank? && last_name.blank?
          pn = practitioner_name
          self.last_name = pn.last_name
          self.first_name = pn.first_name
        end
      end

      # ----------------------------------------------------------------
      # Name formatting (delegates to PatientName value object)
      # ----------------------------------------------------------------

      def practitioner_name
        PatientName.new(name: name, first_name: first_name, last_name: last_name)
      end

      def display_name
        practitioner_name.display
      end

      def formal_name
        practitioner_name.formal
      end

      # ----------------------------------------------------------------
      # FHIR serialization
      # ----------------------------------------------------------------

      def to_fhir
        FHIR::PractitionerSerializer.call(to_serializer_hash)
      end

      def self.from_fhir(fhir_resource)
        new(**FHIR::PractitionerDeserializer.call(fhir_resource))
      end

      def to_param
        practitioner_identifier || ien.to_s
      end

      private

      def to_serializer_hash
        {
          practitioner_identifier: practitioner_identifier || ien&.to_s,
          display_name: name,
          gender: gender,
          npi: npi,
          dea_number: dea_number,
          ien: ien,
          specialty: specialty,
          provider_class: provider_class,
          phone: phone,
          identifiers: []
        }
      end
    end
  end
end
