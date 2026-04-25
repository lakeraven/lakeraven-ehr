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

      attribute :id, :string
      attribute :created_at, :datetime
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
      attribute :request_id, :string
      attribute :disposition, :string

      validates :status, inclusion: { in: VALID_STATUSES }

      def initialize(attributes = {})
        attributes[:id] ||= SecureRandom.uuid
        attributes[:created_at] ||= Time.current
        super
      end

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

      # -- Coverage details --------------------------------------------------

      def coverage_details
        return nil unless enrolled?

        {
          type: coverage_type,
          status: status,
          period: coverage_period,
          plan: plan_info,
          insurer: insurer_info
        }.compact
      end

      def coverage_period
        return nil unless start_date || end_date

        { start: start_date, end: end_date }.compact
      end

      def plan_info
        return nil unless plan_name || policy_id || group_id

        {
          name: plan_name,
          policy_id: policy_id,
          group_id: group_id,
          subscriber_id: subscriber_id
        }.compact
      end

      def insurer_info
        return nil unless insurer_name || insurer_id

        { name: insurer_name, id: insurer_id }.compact
      end

      # -- FHIR serialization ------------------------------------------------

      def to_fhir
        {
          resourceType: "CoverageEligibilityResponse",
          id: id,
          status: "active",
          outcome: fhir_outcome,
          patient: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          request: request_id ? { reference: "CoverageEligibilityRequest/#{request_id}" } : nil,
          insurer: insurer_name ? { display: insurer_name } : nil,
          insurance: build_insurance
        }.compact
      end

      # -- FHIR deserialization -----------------------------------------------

      def self.from_fhir(fhir_hash)
        fhir_hash = fhir_hash.with_indifferent_access if fhir_hash.respond_to?(:with_indifferent_access)

        insurance = fhir_hash["insurance"] || fhir_hash[:insurance]
        outcome = fhir_hash["outcome"] || fhir_hash[:outcome]

        new(
          id: fhir_hash["id"] || fhir_hash[:id],
          patient_dfn: extract_patient_dfn(fhir_hash),
          request_id: extract_request_id(fhir_hash),
          status: outcome_to_status(outcome, insurance: insurance),
          disposition: fhir_hash["disposition"] || fhir_hash[:disposition],
          **extract_coverage_details(fhir_hash)
        )
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

        [{
          coverage: { display: coverage_type },
          benefitPeriod: build_period
        }.compact]
      end

      def build_period
        return nil unless start_date || end_date

        p = {}
        p[:start] = start_date.iso8601 if start_date
        p[:end] = end_date.iso8601 if end_date
        p
      end

      def self.extract_patient_dfn(fhir_hash)
        patient_ref = fhir_hash["patient"] || fhir_hash[:patient]
        return nil unless patient_ref

        reference = patient_ref["reference"] || patient_ref[:reference]
        reference&.gsub("Patient/", "")
      end

      def self.extract_request_id(fhir_hash)
        request_ref = fhir_hash["request"] || fhir_hash[:request]
        return nil unless request_ref

        reference = request_ref["reference"] || request_ref[:reference]
        reference&.gsub("CoverageEligibilityRequest/", "")
      end

      def self.outcome_to_status(outcome, insurance: nil)
        case outcome
        when "complete"
          has_active_coverage?(insurance) ? "enrolled" : "not_enrolled"
        when "queued" then "pending"
        when "error" then "error"
        else "not_enrolled"
        end
      end

      def self.has_active_coverage?(insurance)
        return false if insurance.nil? || insurance.empty?

        insurance.any? do |ins|
          ins[:inforce] == true || ins["inforce"] == true
        end
      end

      def self.extract_coverage_details(fhir_hash)
        insurance = (fhir_hash["insurance"] || fhir_hash[:insurance])&.first
        return {} unless insurance

        period = insurance["benefitPeriod"] || insurance[:benefitPeriod]
        {
          start_date: parse_date(period&.dig(:start) || period&.dig("start")),
          end_date: parse_date(period&.dig(:end) || period&.dig("end"))
        }
      end

      def self.parse_date(value)
        return nil unless value

        Date.parse(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
