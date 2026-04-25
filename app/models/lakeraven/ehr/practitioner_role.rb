# frozen_string_literal: true

module Lakeraven
  module EHR
    class PractitionerRole
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      ROLES = {
        "doctor" => "Doctor",
        "nurse" => "Nurse",
        "pharmacist" => "Pharmacist",
        "surgeon" => "Surgeon",
        "therapist" => "Therapist"
      }.freeze

      attribute :practitioner_ien, :integer
      attribute :organization_ien, :integer
      attribute :role, :string
      attribute :specialty, :string
      attribute :active, :boolean, default: true
      attribute :period_start, :date
      attribute :period_end, :date
      attribute :location_iens # Array

      # =========================================================================
      # VALIDATIONS
      # =========================================================================

      validates :practitioner_ien, presence: true, numericality: { greater_than: 0 }
      validates :organization_ien, presence: true, numericality: { greater_than: 0 }
      validates :role, inclusion: { in: ROLES.keys }, allow_blank: true

      # =========================================================================
      # STATUS HELPERS
      # =========================================================================

      def active? = active

      def valid_for_scheduling?
        active? && within_period?
      end

      def within_period?
        today = Date.current
        (period_start.nil? || today >= period_start) && (period_end.nil? || today <= period_end)
      end

      # =========================================================================
      # ROLE HELPERS
      # =========================================================================

      def role_display
        return "Unknown" if role.blank?
        ROLES[role] || "Unknown"
      end

      # =========================================================================
      # FHIR SERIALIZATION
      # =========================================================================

      def to_fhir
        fhir = {
          resourceType: "PractitionerRole",
          active: active,
          practitioner: practitioner_ien ? { reference: "Practitioner/#{practitioner_ien}" } : nil,
          organization: organization_ien ? { reference: "Organization/#{organization_ien}" } : nil,
          code: build_fhir_code,
          specialty: specialty ? [ { text: specialty } ] : [],
          location: build_fhir_locations,
          period: build_fhir_period
        }.compact
        fhir
      end

      def self.resource_class
        "PractitionerRole"
      end

      def self.from_fhir(fhir_resource)
        attrs = from_fhir_attributes(fhir_resource)
        new(attrs)
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          practitioner_ien: extract_ien_from_reference(fhir_resource.practitioner&.reference),
          organization_ien: extract_ien_from_reference(fhir_resource.organization&.reference),
          specialty: extract_specialty_from_fhir(fhir_resource),
          active: fhir_resource.active.nil? ? true : fhir_resource.active,
          period_start: extract_period_date(fhir_resource.period&.start),
          period_end: extract_period_date(fhir_resource.period&.end)
        }
      end

      private

      def build_fhir_code
        return [] if role.blank?

        [ {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/practitioner-role",
            code: role,
            display: role_display
          } ]
        } ]
      end

      def build_fhir_locations
        iens = location_iens || []
        return [] if iens.empty?
        iens.map { |ien| { reference: "Location/#{ien}" } }
      end

      def build_fhir_period
        return nil if period_start.nil? && period_end.nil?
        {
          start: period_start&.iso8601,
          end: period_end&.iso8601
        }.compact
      end

      def self.extract_ien_from_reference(ref)
        return nil unless ref
        match = ref.match(%r{/(\d+)\z})
        match ? match[1].to_i : nil
      end

      def self.extract_specialty_from_fhir(fhir_resource)
        return nil unless fhir_resource.specialty&.any?
        fhir_resource.specialty.first.text
      end

      def self.extract_period_date(value)
        return nil unless value
        Date.parse(value)
      rescue StandardError
        nil
      end

      private_class_method :extract_ien_from_reference, :extract_specialty_from_fhir, :extract_period_date
    end
  end
end
