# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 CoverageEligibilityRequest -- the inquiry DTO for asking
    # "does this patient have active coverage for this service?"
    #
    # The engine defines the request shape. The actual 270 transaction is
    # performed by an adapter (Stedi in lakeraven-private, mock in tests).
    class CoverageEligibilityRequest
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_PURPOSES = %w[auth-requirements benefits discovery validation].freeze

      INSURER_MAP = {
        "medicare_a" => { reference: "Organization/CMS", display: "Medicare Part A" },
        "medicare_b" => { reference: "Organization/CMS", display: "Medicare Part B" },
        "medicare_d" => { reference: "Organization/CMS", display: "Medicare Part D" },
        "medicaid"   => { reference: "Organization/StateMedicaid", display: "Medicaid" },
        "va_benefits" => { reference: "Organization/VA", display: "VA Benefits" }
      }.freeze

      attribute :id, :string
      attribute :patient_dfn, :string
      attribute :coverage_type, :string
      attribute :purpose, :string, default: "benefits"
      attribute :service_date, :date
      attribute :provider_npi, :string
      attribute :provider_ien, :integer
      attribute :service_type_codes # Array of STC strings

      validates :patient_dfn, presence: true
      validates :coverage_type, presence: true, inclusion: { in: Coverage::COVERAGE_TYPES }
      validates :purpose, inclusion: { in: VALID_PURPOSES }

      def initialize(attributes = {})
        super
        self.service_date ||= Date.current
        self.id ||= SecureRandom.uuid
      end

      def to_fhir
        {
          resourceType: "CoverageEligibilityRequest",
          id: id,
          status: "active",
          purpose: purpose,
          patient: { reference: "Patient/#{patient_dfn}" },
          servicedDate: service_date&.iso8601,
          insurer: build_insurer,
          provider: build_provider,
          insurance: [ { coverage: { display: coverage_type } } ],
          item: [ { category: { coding: [ { code: coverage_type } ] } } ]
        }.compact
      end

      def self.from_fhir(fhir_hash)
        h = fhir_hash.is_a?(Hash) ? fhir_hash : {}
        patient_ref = h[:patient] || h["patient"]
        patient_dfn = patient_ref && (patient_ref[:reference] || patient_ref["reference"])&.gsub("Patient/", "")
        item = (h[:item] || h["item"])&.first
        category_coding = item && (item[:category] || item["category"])
        coding = category_coding && (category_coding[:coding] || category_coding["coding"])&.first
        coverage_type = coding && (coding[:code] || coding["code"])
        serviced = h[:servicedDate] || h["servicedDate"]

        new(
          id: h[:id] || h["id"],
          patient_dfn: patient_dfn,
          coverage_type: coverage_type,
          service_date: serviced ? Date.parse(serviced) : nil
        )
      end

      private

      def build_insurer
        INSURER_MAP[coverage_type]
      end

      def build_provider
        return nil unless provider_npi

        { identifier: { system: "http://hl7.org/fhir/sid/us-npi", value: provider_npi } }
      end
    end
  end
end
