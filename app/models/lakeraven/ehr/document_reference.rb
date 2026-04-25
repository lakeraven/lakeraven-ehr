# frozen_string_literal: true

module Lakeraven
  module EHR
    class DocumentReference
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      # Document status codes (FHIR DocumentReference status)
      STATUSES = {
        "current" => "Current",
        "superseded" => "Superseded",
        "entered-in-error" => "Entered in Error"
      }.freeze

      # Document category codes (US Core DocumentReference categories)
      CATEGORIES = {
        "clinical-note" => "Clinical Note",
        "discharge-summary" => "Discharge Summary",
        "imaging" => "Imaging",
        "imaging-result" => "Imaging Result",
        "laboratory" => "Laboratory",
        "lab-report" => "Lab Report",
        "pathology" => "Pathology",
        "pathology-report" => "Pathology Report",
        "procedure-note" => "Procedure Note",
        "progress-note" => "Progress Note",
        "consult-note" => "Consultation Note"
      }.freeze

      # Common LOINC document type codes
      LOINC_TYPES = {
        "11488-4" => "Consultation Note",
        "18842-5" => "Discharge Summary",
        "34117-2" => "History and Physical Note",
        "11506-3" => "Progress Note",
        "28570-0" => "Procedure Note",
        "18748-4" => "Diagnostic Imaging Report",
        "11502-2" => "Laboratory Report"
      }.freeze

      attribute :id, :string
      attribute :status, :string, default: "current"
      attribute :type_code, :string
      attribute :type_display, :string
      attribute :category, :string
      attribute :subject_patient_dfn, :string
      attribute :author_ien, :string
      attribute :date, :datetime
      attribute :description, :string
      attribute :content_url, :string
      attribute :content_type, :string
      attribute :context_service_request_ien, :string

      # Validations
      validates :subject_patient_dfn, presence: true
      validates :type_code, presence: true
      validates :status, inclusion: { in: STATUSES.keys }, allow_blank: true
      validates :category, inclusion: { in: CATEGORIES.keys }, allow_blank: true

      # =============================================================================
      # PERSISTENCE
      # =============================================================================

      def persisted?
        id.present?
      end

      # =============================================================================
      # STATUS HELPERS
      # =============================================================================

      def current? = status == "current"
      def superseded? = status == "superseded"
      def entered_in_error? = status == "entered-in-error"
      def active? = current?

      def status_display
        STATUSES[status] || "Unknown"
      end

      # =============================================================================
      # CATEGORY HELPERS
      # =============================================================================

      def category_display
        CATEGORIES[category] || "Unknown"
      end

      def clinical_note? = category == "clinical-note"
      def imaging? = category == "imaging"
      def laboratory? = category == "laboratory"

      # =============================================================================
      # TYPE HELPERS
      # =============================================================================

      def type_display_from_loinc
        LOINC_TYPES[type_code] || type_display
      end

      # =============================================================================
      # FHIR SERIALIZATION
      # =============================================================================

      def to_fhir
        {
          resourceType: "DocumentReference",
          id: id,
          status: status,
          type: build_fhir_type,
          category: build_fhir_category,
          subject: subject_patient_dfn ? { reference: "Patient/#{subject_patient_dfn}" } : nil,
          author: build_fhir_author,
          date: date&.strftime("%Y-%m-%d"),
          description: description,
          content: build_fhir_content,
          context: build_fhir_context
        }.compact
      end

      def self.resource_class
        "DocumentReference"
      end

      def self.from_fhir(fhir_resource)
        new(from_fhir_attributes(fhir_resource))
      end

      def self.from_fhir_attributes(fhir_resource)
        attrs = { status: fhir_resource.status }

        if fhir_resource.respond_to?(:type) && fhir_resource.type&.coding&.any?
          coding = fhir_resource.type.coding.first
          attrs[:type_code] = coding.code
          attrs[:type_display] = coding.display
        end

        if fhir_resource.respond_to?(:category) && fhir_resource.category&.any?
          cat = fhir_resource.category.first
          attrs[:category] = cat.coding.first.code if cat.coding&.any?
        end

        if fhir_resource.respond_to?(:subject) && fhir_resource.subject&.reference.present?
          ref = fhir_resource.subject.reference
          if ref.include?("Patient/")
            dfn = ref.split("/").last.gsub(/\D/, "")
            attrs[:subject_patient_dfn] = dfn if dfn.present?
          end
        end

        if fhir_resource.respond_to?(:author) && fhir_resource.author&.any?
          ref = fhir_resource.author.first&.reference
          if ref&.include?("Practitioner/")
            ien = ref.split("/").last.gsub(/\D/, "")
            attrs[:author_ien] = ien if ien.present?
          end
        end

        if fhir_resource.respond_to?(:date) && fhir_resource.date.present?
          date_value = fhir_resource.date
          attrs[:date] = date_value.is_a?(String) ? Date.parse(date_value) : date_value
        end

        attrs[:description] = fhir_resource.description if fhir_resource.respond_to?(:description)

        if fhir_resource.respond_to?(:content) && fhir_resource.content&.any?
          attachment = fhir_resource.content.first&.attachment
          if attachment
            attrs[:content_url] = attachment.url if attachment.respond_to?(:url)
            attrs[:content_type] = attachment.contentType if attachment.respond_to?(:contentType)
          end
        end

        attrs
      end

      private

      def build_fhir_type
        return nil if type_code.blank?

        {
          coding: [
            {
              system: "http://loinc.org",
              code: type_code,
              display: type_display_from_loinc
            }
          ]
        }
      end

      def build_fhir_category
        return [] if category.blank?

        [
          {
            coding: [
              {
                system: "http://hl7.org/fhir/us/core/CodeSystem/us-core-documentreference-category",
                code: category,
                display: category_display
              }
            ]
          }
        ]
      end

      def build_fhir_author
        return [] if author_ien.blank?

        [ { reference: "Practitioner/rpms-practitioner-#{author_ien}" } ]
      end

      def build_fhir_content
        return [] unless content_url.present? || content_type.present?

        [ { attachment: { contentType: content_type, url: content_url } } ]
      end

      def build_fhir_context
        return nil if context_service_request_ien.blank?

        {
          related: [
            { reference: "ServiceRequest/rpms-service-request-#{context_service_request_ien}" }
          ]
        }
      end
    end
  end
end
