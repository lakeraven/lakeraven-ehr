# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 Coverage — patient insurance record.
    # Used for eligibility checks and coordination of benefits.
    class Coverage
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      COVERAGE_TYPES = %w[
        medicare_a medicare_b medicare_d medicaid private_insurance
        va_benefits workers_comp auto_insurance state_program tribal_program
      ].freeze

      FHIR_STATUSES = %w[active cancelled draft entered-in-error].freeze
      PRC_STATUSES = %w[exhausted not_enrolled denied pending].freeze
      VALID_STATUSES = (FHIR_STATUSES + PRC_STATUSES).freeze

      attribute :patient_dfn, :string
      attribute :coverage_type, :string
      attribute :status, :string, default: "active"
      attribute :payor_name, :string
      attribute :payor_id, :string
      attribute :subscriber_id, :string
      attribute :member_id, :string
      attribute :group_id, :string
      attribute :dependent_number, :string
      attribute :relationship, :string, default: "self"
      attribute :start_date, :date
      attribute :end_date, :date
      attribute :order, :integer

      validates :patient_dfn, presence: true
      validates :coverage_type, presence: true, inclusion: { in: COVERAGE_TYPES }
      validates :status, inclusion: { in: VALID_STATUSES }

      # -- Status helpers ----------------------------------------------------

      def active?
        status == "active" && within_coverage_period?
      end

      def expired?
        end_date.present? && end_date < Date.current
      end

      def cancelled?
        status == "cancelled"
      end

      def within_coverage_period?
        return true unless start_date || end_date

        today = Date.current
        (start_date.nil? || today >= start_date) && (end_date.nil? || today <= end_date)
      end

      # -- Payor helpers -----------------------------------------------------

      def medicare?
        coverage_type&.start_with?("medicare")
      end

      def medicaid?
        coverage_type == "medicaid"
      end

      def private_insurance?
        coverage_type == "private_insurance"
      end

      def va_benefits?
        coverage_type == "va_benefits"
      end

      def government_payer?
        medicare? || medicaid? || va_benefits?
      end

      # -- COB ---------------------------------------------------------------

      def primary?
        order == 1
      end

      def secondary?
        order == 2
      end

      # -- FHIR serialization ------------------------------------------------

      def to_fhir
        {
          resourceType: "Coverage",
          status: status,
          beneficiary: { reference: "Patient/#{patient_dfn}" },
          payor: payor_name ? [ { display: payor_name } ] : [],
          period: build_period,
          class: build_class_array,
          order: order
        }.compact
      end

      private

      def build_period
        return nil unless start_date || end_date

        p = {}
        p[:start] = start_date.iso8601 if start_date
        p[:end] = end_date.iso8601 if end_date
        p
      end

      def build_class_array
        classes = []
        classes << { type: { coding: [ { code: "group" } ] }, value: group_id } if group_id
        classes << { type: { coding: [ { code: "plan" } ] }, value: subscriber_id } if subscriber_id
        classes.empty? ? nil : classes
      end
    end
  end
end
