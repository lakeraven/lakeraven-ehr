# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR CareTeam resource (Patient-specific from RPMS) - ActiveModel
    # ONC 170.315(g)(10) - Required for patient care team access
    # USCDI v3 Data Class: Care Team Member(s)
    class CareTeam
      include ActiveModel::Model
      include ActiveModel::Attributes

      US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-careteam"

      VALID_STATUSES = %w[proposed active suspended inactive entered-in-error].freeze

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :name, :string
      attribute :status, :string
      attribute :category, :string
      attribute :period_start, :date
      attribute :period_end, :date
      attribute :reason_code, :string
      attribute :reason_display, :string
      attribute :managing_organization, :string

      # Participants stored as array of hashes
      attr_accessor :participants

      def initialize(attributes = {})
        items = attributes.delete(:participants) || []
        super(attributes)
        @participants = items
      end

      validates :patient_dfn, presence: true
      validates :status, inclusion: { in: VALID_STATUSES, allow_blank: true }

      def id
        ien
      end

      def persisted?
        ien.present?
      end

      # -- FHIR serialization (hash-based) -------------------------------------

      def to_fhir
        resource = {
          resourceType: "CareTeam",
          id: "rpms-ct-#{ien}",
          meta: { profile: [ US_CORE_PROFILE ] },
          status: status || "active",
          name: name,
          category: build_categories,
          subject: { reference: "Patient/rpms-#{patient_dfn}" },
          period: build_period,
          participant: build_participants,
          reasonCode: build_reason_code,
          managingOrganization: build_managing_organization
        }
        resource
      end

      def self.resource_class
        "CareTeam"
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          name: fhir_resource.name,
          status: fhir_resource.status
        }
      end

      private

      def build_categories
        [ {
          coding: [ {
            system: "http://loinc.org",
            code: "LA27976-2",
            display: "Encounter-focused care team"
          } ]
        } ]
      end

      def build_period
        return nil if period_start.blank? && period_end.blank?
        { start: period_start&.iso8601, end: period_end&.iso8601 }
      end

      def build_participants
        return [] if participants.blank?

        participants.map do |member|
          {
            role: build_participant_role(member["role"]),
            member: {
              reference: "Practitioner/rpms-#{member['duz']}",
              display: member["name"]
            },
            period: member["start_date"].present? ? {
              start: member["start_date"],
              end: member["end_date"]
            } : nil
          }
        end
      end

      def build_participant_role(role)
        return nil if role.blank?
        [ { coding: [], text: role } ]
      end

      def build_reason_code
        return nil if reason_code.blank? && reason_display.blank?
        [ {
          coding: reason_code.present? ? [ { code: reason_code } ] : [],
          text: reason_display
        } ]
      end

      def build_managing_organization
        return nil if managing_organization.blank?
        [ { display: managing_organization } ]
      end
    end
  end
end
