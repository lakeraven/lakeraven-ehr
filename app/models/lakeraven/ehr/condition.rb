# frozen_string_literal: true

module Lakeraven
  module EHR
    class Condition
      include ActiveModel::Model
      include ActiveModel::Attributes

      VALID_CLINICAL_STATUSES = %w[active recurrence relapse inactive remission resolved].freeze
      VALID_CATEGORIES = %w[problem-list-item encounter-diagnosis health-concern].freeze
      VALID_CODE_SYSTEMS = %w[icd10 snomed].freeze

      SEVERITY_SNOMED = {
        "severe" => "24484000",
        "moderate" => "6736007",
        "mild" => "255604002"
      }.freeze

      CODE_SYSTEM_URLS = {
        "icd10" => "http://hl7.org/fhir/sid/icd-10-cm",
        "snomed" => "http://snomed.info/sct"
      }.freeze

      CATEGORY_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-category"
      DATA_ABSENT_REASON = "http://hl7.org/fhir/StructureDefinition/data-absent-reason"

      # ORQQPL status codes that are real condition-clinical values.
      # Anything else, including blank, is not coded — to_fhir marks it absent.
      RPMS_PROBLEM_STATUS = { "A" => "active", "I" => "inactive" }.freeze

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :code, :string
      attribute :code_system, :string
      attribute :display, :string
      attribute :clinical_status, :string
      attribute :verification_status, :string
      attribute :category, :string
      attribute :severity, :string
      attribute :onset_datetime, :datetime
      attribute :recorded_date, :date

      validates :patient_dfn, presence: true
      validates :display, presence: true
      validates :clinical_status, inclusion: { in: VALID_CLINICAL_STATUSES, allow_blank: true }
      validates :category, inclusion: { in: VALID_CATEGORIES, allow_blank: true }
      validates :code_system, inclusion: { in: VALID_CODE_SYSTEMS, allow_blank: true }

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || ConditionGateway
        end
      end

      def self.for_patient(dfn)
        gateway.for_patient(dfn)
      end

      # Problem-list gateway row -> model. Shared by the chart and Condition search.
      def self.from_rpms_row(row, patient_dfn:)
        new(
          ien: problem_id(patient_dfn, row),
          patient_dfn: patient_dfn,
          code: row[:icd_code],
          code_system: "icd10",
          display: row[:description],
          clinical_status: RPMS_PROBLEM_STATUS[row[:status].to_s.strip],
          category: "problem-list-item"
        )
      end

      # Prefer a real IEN; otherwise a stable id (never random/urn:uuid) so a
      # Bundle entry's subject reference stays resolvable.
      def self.problem_id(patient_dfn, row)
        row[:ien].to_s.presence || "problem-#{patient_dfn}-#{row[:icd_code].to_s.parameterize}"
      end
      private_class_method :problem_id

      def self.resource_class
        "Condition"
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          code: fhir_resource.code&.coding&.first&.code,
          display: fhir_resource.code&.text || fhir_resource.code&.coding&.first&.display,
          clinical_status: fhir_resource.clinicalStatus&.coding&.first&.code,
          verification_status: fhir_resource.verificationStatus&.coding&.first&.code,
          category: fhir_resource.category&.first&.coding&.first&.code
        }
      end

      def active? = clinical_status == "active"
      def resolved? = clinical_status == "resolved"
      def problem_list_item? = category == "problem-list-item"

      # Matching key for clinical reconciliation (ONC § 170.315(b)(2))
      def matching_key
        if code.present?
          system = code_system || "icd10"
          "#{system}:#{code}"
        elsif display.present?
          "name:#{display.downcase.strip}"
        end
      end

      def persisted?
        ien.present?
      end

      def to_fhir
        {
          resourceType: "Condition",
          id: ien&.to_s,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          clinicalStatus: build_clinical_status,
          code: build_code,
          category: category ? [ { coding: [ { system: CATEGORY_SYSTEM, code: category } ] } ] : nil,
          severity: build_severity
        }.compact
      end

      private

      def build_clinical_status
        if clinical_status.present?
          {
            coding: [ {
              system: "http://terminology.hl7.org/CodeSystem/condition-clinical",
              code: clinical_status
            } ]
          }
        else
          {
            extension: [ { url: DATA_ABSENT_REASON, valueCode: "unknown" } ]
          }
        end
      end

      def build_code
        return nil unless code || display

        result = {}
        if code
          system_url = CODE_SYSTEM_URLS[code_system] || CODE_SYSTEM_URLS["icd10"]
          result[:coding] = [ { code: code, system: system_url } ]
        end
        result[:text] = display if display
        result
      end

      def build_severity
        return nil unless severity.present?

        snomed_code = SEVERITY_SNOMED[severity&.downcase]
        return nil unless snomed_code

        {
          coding: [ {
            system: "http://snomed.info/sct",
            code: snomed_code,
            display: severity.capitalize
          } ]
        }
      end
    end
  end
end
