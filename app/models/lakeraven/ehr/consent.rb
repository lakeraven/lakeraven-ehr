# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR Consent resource - ActiveModel (RPC-backed)
    # Manages patient consent for proxy access and authorization.
    class Consent
      include ActiveModel::Model
      include ActiveModel::Attributes

      # Consent status codes
      STATUSES = {
        "draft" => "Draft",
        "proposed" => "Proposed",
        "active" => "Active",
        "rejected" => "Rejected",
        "inactive" => "Inactive",
        "revoked" => "Revoked",
        "expired" => "Expired",
        "entered-in-error" => "Entered in Error"
      }.freeze

      # Consent scope codes (FHIR + legacy scopes)
      SCOPES = {
        "patient-privacy" => "Privacy Consent",
        "treatment" => "Treatment",
        "research" => "Research",
        "adr" => "Advance Directive",
        "hipaa-auth" => "HIPAA Authorization",
        "view_referrals" => "View Referrals",
        "view_records" => "View Records",
        "upload_docs" => "Upload Documents",
        "message" => "Message",
        "full_access" => "Full Access"
      }.freeze

      # Provision types
      PROVISION_TYPES = {
        "permit" => "Permit",
        "deny" => "Deny"
      }.freeze

      CATEGORY_CODE = "59284-0"
      CATEGORY_DISPLAY = "Consent Document"

      # -- Attributes ----------------------------------------------------------

      attribute :id, :string
      attribute :patient_dfn, :string
      attribute :scope, :string
      attribute :status, :string
      attribute :provision_type, :string
      attribute :period_start, :date
      attribute :period_end, :date
      attribute :date_time, :date
      attribute :performer_ien, :string
      attribute :grantee_type, :string
      attribute :grantee_id, :string
      attribute :starts_at, :datetime
      attribute :expires_at, :datetime
      attribute :revoked_at, :datetime
      attribute :revocation_reason, :string
      attribute :provision_actor_related_person_id, :string
      attribute :provision_actor_practitioner_ien, :string
      attribute :provision_action, :string

      # -- Validations ---------------------------------------------------------

      validates :patient_dfn, presence: true
      validates :scope, presence: true, inclusion: { in: SCOPES.keys }
      validates :status, inclusion: { in: STATUSES.keys }, allow_blank: true
      validates :provision_type, inclusion: { in: PROVISION_TYPES.keys }, allow_blank: true

      # -- Persistence ---------------------------------------------------------

      def persisted?
        id.present?
      end

      # -- Status helpers ------------------------------------------------------

      def active?       = status == "active"
      def draft?        = status == "draft"
      def proposed?     = status == "proposed"
      def rejected?     = status == "rejected"
      def inactive?     = status == "inactive"
      def enforceable?  = active?
      def status_display = STATUSES[status] || "Unknown"

      # -- Scope helpers -------------------------------------------------------

      def scope_display    = SCOPES[scope] || "Unknown"
      def patient_privacy? = scope == "patient-privacy"
      def treatment?       = scope == "treatment"
      def research?        = scope == "research"

      # -- Provision helpers ---------------------------------------------------

      def permits?               = provision_type == "permit"
      def denies?                = provision_type == "deny"
      def provision_type_display = PROVISION_TYPES[provision_type] || "Unknown"

      # -- Validity period -----------------------------------------------------

      def within_period?
        today = Date.current
        start_ok = period_start.nil? || period_start <= today
        end_ok = period_end.nil? || period_end >= today
        start_ok && end_ok
      end

      # -- Authorization -------------------------------------------------------

      def authorizes_access?
        enforceable? && permits? && within_period?
      end

      def allows?(permission)
        return false unless active?
        scope == "full_access" || scope == permission.to_s
      end

      def expired?
        expires_at.present? && expires_at <= Time.current
      end

      # -- FHIR serialization (hash-based) -------------------------------------

      def to_fhir
        resource = {
          resourceType: "Consent",
          status: status,
          patient: patient_dfn.present? ? { reference: "Patient/#{patient_dfn}" } : nil,
          scope: build_fhir_scope,
          category: build_fhir_category,
          dateTime: date_time&.iso8601,
          performer: build_fhir_performer,
          provision: build_fhir_provision
        }
        resource[:id] = id.to_s if id.present?
        resource
      end

      def self.resource_class
        "Consent"
      end

      def self.from_fhir(fhir_resource)
        new(from_fhir_attributes(fhir_resource))
      end

      def self.from_fhir_attributes(fhir_resource)
        attrs = { status: fhir_resource.status }

        if fhir_resource.respond_to?(:scope) && fhir_resource.scope&.coding&.any?
          attrs[:scope] = fhir_resource.scope.coding.first.code
        end

        if fhir_resource.respond_to?(:patient) && fhir_resource.patient&.reference.present?
          ref = fhir_resource.patient.reference
          if ref.include?("Patient/")
            dfn = ref.split("/").last.gsub(/\D/, "")
            attrs[:patient_dfn] = dfn if dfn.present?
          end
        end

        if fhir_resource.respond_to?(:dateTime) && fhir_resource.dateTime.present?
          attrs[:date_time] = Date.parse(fhir_resource.dateTime)
        end

        attrs
      end

      private

      def build_fhir_scope
        return nil if scope.blank?
        {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/consentscope",
            code: scope,
            display: scope_display
          } ]
        }
      end

      def build_fhir_category
        [ {
          coding: [ {
            system: "http://loinc.org",
            code: CATEGORY_CODE,
            display: CATEGORY_DISPLAY
          } ]
        } ]
      end

      def build_fhir_performer
        return [] unless performer_ien.present?
        [ { reference: "Practitioner/rpms-practitioner-#{performer_ien}" } ]
      end

      def build_fhir_provision
        return nil if provision_type.blank?
        {
          type: provision_type,
          actor: build_provision_actors,
          action: build_provision_actions,
          period: build_provision_period
        }
      end

      def build_provision_actors
        actors = []
        if provision_actor_related_person_id.present?
          actors << {
            role: { coding: [ { code: "DPOWATT", display: "Durable Power of Attorney" } ] },
            reference: { reference: "RelatedPerson/#{provision_actor_related_person_id}" }
          }
        end
        if provision_actor_practitioner_ien.present?
          actors << {
            role: { coding: [ { code: "CST", display: "Custodian" } ] },
            reference: { reference: "Practitioner/rpms-practitioner-#{provision_actor_practitioner_ien}" }
          }
        end
        actors
      end

      def build_provision_actions
        return nil if provision_action.blank?
        [ { coding: [ { system: "http://terminology.hl7.org/CodeSystem/consentaction", code: provision_action } ] } ]
      end

      def build_provision_period
        return nil if period_start.blank? && period_end.blank?
        { start: period_start&.iso8601, end: period_end&.iso8601 }
      end
    end
  end
end
