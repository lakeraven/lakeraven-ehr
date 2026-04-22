# frozen_string_literal: true

module Lakeraven
  module EHR
    class PractitionerRole
      include ActiveModel::Model
      include ActiveModel::Attributes

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

      def active? = active
      def role_display = ROLES[role] || role

      def within_period?
        today = Date.current
        (period_start.nil? || today >= period_start) && (period_end.nil? || today <= period_end)
      end

      def to_fhir
        {
          resourceType: "PractitionerRole",
          active: active,
          practitioner: { reference: "Practitioner/#{practitioner_ien}" },
          organization: organization_ien ? { reference: "Organization/#{organization_ien}" } : nil,
          code: role ? [ { text: role_display } ] : [],
          specialty: specialty ? [ { text: specialty } ] : []
        }.compact
      end
    end
  end
end
