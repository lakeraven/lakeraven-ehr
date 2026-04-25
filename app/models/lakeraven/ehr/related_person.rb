# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR RelatedPerson resource - ActiveModel (RPC-backed)
    # Represents patient advocates, family caregivers, and authorized representatives.
    class RelatedPerson
      include ActiveModel::Model
      include ActiveModel::Attributes

      # Relationship codes (based on HL7 v2-0131)
      RELATIONSHIPS = {
        "parent" => "Parent",
        "spouse" => "Spouse",
        "child" => "Child",
        "sibling" => "Sibling",
        "guardian" => "Guardian",
        "friend" => "Friend",
        "caregiver" => "Caregiver",
        "advocate" => "Patient Advocate",
        "emergency" => "Emergency Contact",
        "other" => "Other"
      }.freeze

      # -- Attributes ----------------------------------------------------------

      attribute :id, :string
      attribute :patient_dfn, :string
      attribute :name, :string
      attribute :relationship, :string
      attribute :active, :boolean
      attribute :phone, :string
      attribute :email, :string
      attribute :period_start, :date
      attribute :period_end, :date

      # -- Validations ---------------------------------------------------------

      validates :patient_dfn, presence: true
      validates :name, presence: true
      validates :relationship, presence: true, inclusion: { in: RELATIONSHIPS.keys }

      # -- Persistence ---------------------------------------------------------

      def persisted?
        id.present?
      end

      # -- Status helpers ------------------------------------------------------

      def active?
        active == true
      end

      def within_period?
        today = Date.current
        start_ok = period_start.nil? || period_start <= today
        end_ok = period_end.nil? || period_end >= today
        start_ok && end_ok
      end

      def valid_for_authorization?
        active? && within_period?
      end

      # -- Relationship helpers ------------------------------------------------

      def relationship_display = RELATIONSHIPS[relationship] || "Unknown"
      def guardian?            = relationship == "guardian"
      def caregiver?           = relationship == "caregiver"

      def family_member?
        %w[parent spouse child sibling].include?(relationship)
      end

      # -- FHIR serialization (hash-based) -------------------------------------

      def to_fhir
        resource = {
          resourceType: "RelatedPerson",
          active: active,
          patient: patient_dfn.present? ? { reference: "Patient/#{patient_dfn}" } : nil,
          relationship: build_fhir_relationship,
          name: build_fhir_name,
          telecom: build_fhir_telecom,
          period: build_fhir_period
        }
        resource[:id] = id.to_s if id.present?
        resource
      end

      def self.resource_class
        "RelatedPerson"
      end

      def self.from_fhir(fhir_resource)
        new(from_fhir_attributes(fhir_resource))
      end

      def self.from_fhir_attributes(fhir_resource)
        attrs = { active: fhir_resource.active }

        if fhir_resource.respond_to?(:patient) && fhir_resource.patient&.reference.present?
          ref = fhir_resource.patient.reference
          if ref.include?("Patient/")
            dfn = ref.split("/").last.gsub(/\D/, "")
            attrs[:patient_dfn] = dfn if dfn.present?
          end
        end

        if fhir_resource.respond_to?(:relationship) && fhir_resource.relationship&.any?
          rel = fhir_resource.relationship.first
          attrs[:relationship] = rel.coding.first.code if rel.coding&.any?
        end

        if fhir_resource.respond_to?(:name) && fhir_resource.name&.any?
          n = fhir_resource.name.first
          attrs[:name] = n.text || "#{n.given&.join(' ')} #{n.family}".strip
        end

        attrs
      end

      private

      def build_fhir_relationship
        return [] if relationship.blank?
        [ {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/v2-0131",
            code: relationship,
            display: relationship_display
          } ]
        } ]
      end

      def build_fhir_name
        return [] if name.blank?
        [ { text: name } ]
      end

      def build_fhir_telecom
        telecoms = []
        telecoms << { system: "phone", value: phone } if phone.present?
        telecoms << { system: "email", value: email } if email.present?
        telecoms
      end

      def build_fhir_period
        return nil if period_start.blank? && period_end.blank?
        { start: period_start&.iso8601, end: period_end&.iso8601 }
      end
    end
  end
end
