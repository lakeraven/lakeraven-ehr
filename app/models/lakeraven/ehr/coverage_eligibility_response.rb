# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 CoverageEligibilityResponse — result of a 271 eligibility check.
    # Holds coverage status, plan details, and error information.
    #
    # Created by the eligibility adapter (Stedi in lakeraven-private, mock in tests).
    class CoverageEligibilityResponse
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_STATUSES = %w[enrolled not_enrolled pending denied exhausted error].freeze
      TERMINAL_STATUSES = %w[enrolled not_enrolled denied exhausted].freeze
      TRANSIENT_ERROR_CODES = %w[42 80].freeze

      attribute :patient_dfn, :string
      attribute :coverage_type, :string
      attribute :status, :string
      attribute :plan_name, :string
      attribute :policy_id, :string
      attribute :group_id, :string
      attribute :subscriber_id, :string
      attribute :insurer_name, :string
      attribute :insurer_id, :string
      attribute :start_date, :date
      attribute :end_date, :date
      attribute :error_code, :string
      attribute :error_message, :string

      validates :status, inclusion: { in: VALID_STATUSES }

      # -- Status helpers ----------------------------------------------------

      def enrolled?
        status == "enrolled"
      end

      def not_enrolled?
        status == "not_enrolled"
      end

      def error?
        status == "error"
      end

      def pending?
        status == "pending"
      end

      def denied?
        status == "denied"
      end

      def exhausted?
        status == "exhausted"
      end

      def active_coverage?
        enrolled? && within_coverage_period?
      end

      def within_coverage_period?
        return true unless start_date || end_date

        today = Date.current
        (start_date.nil? || today >= start_date) && (end_date.nil? || today <= end_date)
      end

      def final?
        TERMINAL_STATUSES.include?(status)
      end

      # -- Error helpers (AAA codes from Stedi article) ----------------------

      def transient_error?
        error? && TRANSIENT_ERROR_CODES.include?(error_code)
      end

      # -- FHIR serialization ------------------------------------------------

      def to_fhir
        {
          resourceType: "CoverageEligibilityResponse",
          status: "active",
          outcome: fhir_outcome,
          patient: { reference: "Patient/#{patient_dfn}" },
          insurer: insurer_name ? { display: insurer_name } : nil,
          insurance: build_insurance
        }.compact
      end

      private

      def fhir_outcome
        case status
        when "enrolled", "not_enrolled", "denied", "exhausted" then "complete"
        when "pending" then "queued"
        when "error" then "error"
        end
      end

      def build_insurance
        return nil unless enrolled?

        [ {
          coverage: { display: coverage_type },
          benefitPeriod: build_period
        }.compact ]
      end

      def build_period
        return nil unless start_date || end_date

        p = {}
        p[:start] = start_date.iso8601 if start_date
        p[:end] = end_date.iso8601 if end_date
        p
      end
    end
  end
end
