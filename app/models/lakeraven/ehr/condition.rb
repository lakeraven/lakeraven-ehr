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

      US_CORE_CONDITION_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-condition"
      CATEGORY_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-category"

      # ORQQPL LIST status codes → FHIR condition-clinical codes.
      PROBLEM_STATUS_MAP = {
        "A" => "active",
        "I" => "inactive"
      }.freeze

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

      # Build Condition instances from raw problem-list rows and return them
      # ready for FHIR serialization. Rows come from ORQQPL LIST on both
      # backends: { ien:, description:, status:, icd_code:, onset_date:,
      # modified_date:, service_connected: }.
      def self.fhir_for_patient(dfn)
        from_problem_hashes(gateway.for_patient(dfn), patient_dfn: dfn)
      end

      # NOTE: the row's modified_date is the problem's last-modified date,
      # not its recorded date, so it is deliberately not mapped to FHIR
      # recordedDate. The icd_code system claim comes from the mapping's
      # terminology annotation; the wire row's coding-system piece (ICD-9
      # vs ICD-10) is not yet mapped.
      def self.from_problem_hashes(hashes, patient_dfn:)
        hashes.map do |h|
          new(
            ien: h[:ien]&.to_s,
            patient_dfn: patient_dfn.to_s,
            code: h[:icd_code].presence,
            code_system: h[:icd_code].present? ? "icd10" : nil,
            display: h[:description],
            clinical_status: PROBLEM_STATUS_MAP[h[:status].to_s.upcase],
            category: "problem-list-item",
            onset_datetime: h[:onset_date]
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
        resource = {
          resourceType: "Condition",
          id: ien&.to_s,
          meta: build_meta,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          clinicalStatus: build_clinical_status,
          verificationStatus: build_verification_status,
          code: build_code,
          category: category ? [ { coding: [ { code: category, system: CATEGORY_SYSTEM } ] } ] : nil,
          severity: build_severity,
          onsetDateTime: onset_datetime&.iso8601,
          recordedDate: recorded_date&.iso8601
        }.compact

        Lakeraven::EHR::FHIR::UsCoreValidator.validate!(resource) if Lakeraven::EHR.configuration.validate_fhir_us_core

        resource
      end

      private

      # Claim US Core conformance only when the profile's required elements
      # are present (same conditional-claim pattern as Observation); the
      # UsCoreValidator then enforces the rest whenever the claim is made.
      def build_meta
        return nil unless patient_dfn.present? && category.present? && (code.present? || display.present?)

        { profile: [ US_CORE_CONDITION_PROFILE ] }
      end

      def build_verification_status
        return nil unless verification_status.present?

        {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/condition-ver-status",
            code: verification_status
          } ]
        }
      end

      def build_clinical_status
        return nil unless clinical_status

        {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/condition-clinical",
            code: clinical_status
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
