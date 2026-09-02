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

      # ORQQPL LIST problem-status codes ("A"/"I") -> FHIR clinicalStatus.
      RPMS_STATUS_MAP = { "A" => "active", "I" => "inactive" }.freeze

      # Build Condition instances from raw ORQQPL LIST rows
      # ({ ien:, status:, description:, icd_code:, onset_date:,
      # recorded_date:, provider_duz: }). Problems on the RPMS Integrated
      # Problem List are clinician-recorded diagnoses, so verificationStatus
      # maps to "confirmed" (US Core problem-list convention). Ids prefer the
      # real IEN and otherwise derive deterministically from dfn + code so
      # they stay stable across reads (Vardana §5.3).
      def self.from_problem_hashes(hashes, patient_dfn:)
        hashes.map do |h|
          new(
            ien: h[:ien].to_s.presence || "problem-#{patient_dfn}-#{h[:icd_code].to_s.parameterize}",
            patient_dfn: patient_dfn,
            code: h[:icd_code],
            code_system: "icd10",
            display: h[:description],
            clinical_status: RPMS_STATUS_MAP[h[:status]] || "active",
            verification_status: "confirmed",
            category: "problem-list-item",
            onset_datetime: h[:onset_date],
            recorded_date: h[:recorded_date]
          )
        end
      end

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
          verificationStatus: build_verification_status,
          code: build_code,
          category: category ? [ { coding: [ { system: CATEGORY_SYSTEM, code: category } ] } ] : nil,
          severity: build_severity,
          onsetDateTime: onset_datetime&.iso8601,
          recordedDate: recorded_date&.iso8601
        }.compact
      end

      private

      def build_clinical_status
        return nil unless clinical_status

        {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/condition-clinical",
            code: clinical_status
          } ]
        }
      end

      def build_verification_status
        return nil unless verification_status

        {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/condition-ver-status",
            code: verification_status
          } ]
        }
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
