# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 CoverageEligibilityRequest — the inquiry DTO for asking
    # "does this patient have active coverage for this service?"
    #
    # The engine defines the request shape. The actual 270 transaction is
    # performed by an adapter (Stedi in lakeraven-private, mock in tests).
    class CoverageEligibilityRequest
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_PURPOSES = %w[auth-requirements benefits discovery validation].freeze

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
      end

      def to_fhir
        {
          resourceType: "CoverageEligibilityRequest",
          status: "active",
          purpose: purpose,
          patient: { reference: "Patient/#{patient_dfn}" },
          servicedDate: service_date&.iso8601,
          provider: provider_npi ? { identifier: { system: "http://hl7.org/fhir/sid/us-npi", value: provider_npi } } : nil,
          insurance: [ { coverage: { display: coverage_type } } ]
        }.compact
      end
    end
  end
end
