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

      attribute :id, :string
      attribute :created_at, :datetime
      attribute :patient_dfn, :string
      attribute :coverage_type, :string
      attribute :status, :string, default: "active"
      attribute :payor_name, :string
      attribute :payor_id, :string
      attribute :payor_type, :string
      attribute :subscriber_id, :string
      attribute :member_id, :string
      attribute :group_id, :string
      attribute :plan_name, :string
      attribute :plan_id, :string
      attribute :dependent_number, :string
      attribute :relationship, :string, default: "self"
      attribute :start_date, :date
      attribute :end_date, :date
      attribute :order, :integer

      validates :patient_dfn, presence: true
      validates :coverage_type, presence: true, inclusion: { in: COVERAGE_TYPES }
      validates :status, inclusion: { in: VALID_STATUSES }

      def initialize(attributes = {})
        attributes[:id] ||= SecureRandom.uuid
        attributes[:created_at] ||= Time.current
        super
      end

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

      # Display name for the payor
      def payor_display
        payor_name || default_payor_name
      end

      # Display name for the payor type (e.g., "Medicare Part A")
      def payor_type_display
        payor_type || default_payor_type
      end

      # -- COB ---------------------------------------------------------------

      def coordination_order
        order || default_coordination_order
      end

      def primary?
        coordination_order == 1
      end

      def secondary?
        coordination_order == 2
      end

      # -- FHIR serialization ------------------------------------------------

      def to_fhir
        {
          resourceType: "Coverage",
          id: id,
          status: status,
          beneficiary: { reference: "Patient/#{patient_dfn}" },
          payor: [ payor_fhir_reference ],
          period: build_period,
          class: build_class_array,
          order: order
        }.compact
      end

      # -- FHIR parsing (class methods) --------------------------------------

      def self.from_fhir(fhir_hash)
        new(
          id: fhir_hash[:id] || fhir_hash["id"],
          patient_dfn: extract_patient_dfn(fhir_hash),
          status: fhir_hash[:status] || fhir_hash["status"] || "active",
          coverage_type: extract_coverage_type(fhir_hash),
          payor_name: extract_payor_name(fhir_hash),
          **extract_period(fhir_hash),
          **extract_class_info(fhir_hash)
        )
      end

      def self.from_eligibility_response(response)
        return nil unless response.enrolled?

        new(
          patient_dfn: response.patient_dfn,
          coverage_type: response.coverage_type,
          status: "active",
          start_date: response.start_date,
          end_date: response.end_date,
          plan_name: response.plan_name,
          member_id: response.policy_id,
          group_id: response.group_id
        )
      end

      private

      def default_payor_name
        case coverage_type
        when "medicare_a", "medicare_b", "medicare_d" then "Medicare"
        when "medicaid" then "Medicaid"
        when "va_benefits" then "Department of Veterans Affairs"
        when "workers_comp" then "Workers Compensation"
        when "auto_insurance" then "Auto Insurance"
        when "state_program" then "State Health Program"
        when "tribal_program" then "Tribal Health Program"
        when "private_insurance" then "Private Insurance"
        end
      end

      def default_payor_type
        case coverage_type
        when "medicare_a" then "Medicare Part A"
        when "medicare_b" then "Medicare Part B"
        when "medicare_d" then "Medicare Part D"
        when "medicaid" then "Medicaid"
        when "va_benefits" then "VA Benefits"
        when "private_insurance" then "Private Insurance"
        else coverage_type&.titleize
        end
      end

      def default_coordination_order
        case coverage_type
        when "private_insurance" then 1
        when "medicare_a", "medicare_b", "medicare_d" then 2
        when "medicaid" then 3
        when "va_benefits" then 2
        when "workers_comp", "auto_insurance" then 1
        else 4
        end
      end

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
        if plan_name.present? || subscriber_id.present?
          classes << {
            type: { coding: [ { code: "plan" } ] },
            value: subscriber_id || plan_name,
            name: plan_name
          }.compact
        end
        classes.empty? ? nil : classes
      end

      def payor_fhir_reference
        {
          reference: payor_org_reference,
          display: payor_display
        }
      end

      def payor_org_reference
        case coverage_type
        when "medicare_a", "medicare_b", "medicare_d" then "Organization/CMS"
        when "medicaid" then "Organization/StateMedicaid"
        when "va_benefits" then "Organization/VA"
        else "Organization/#{payor_id || coverage_type&.camelize}"
        end
      end

      # -- FHIR parsing helpers (class-level) --------------------------------

      def self.extract_patient_dfn(fhir_hash)
        beneficiary = fhir_hash[:beneficiary] || fhir_hash["beneficiary"]
        return nil unless beneficiary
        reference = beneficiary[:reference] || beneficiary["reference"]
        reference&.gsub("Patient/", "")
      end

      def self.extract_coverage_type(fhir_hash)
        type = fhir_hash[:type] || fhir_hash["type"]
        return nil unless type
        coding = type[:coding]&.first || type["coding"]&.first
        code = coding&.dig(:code) || coding&.dig("code")

        case code
        when "MEDICARE" then "medicare_a"
        when "MEDICAID" then "medicaid"
        when "HIP" then "private_insurance"
        when "VET" then "va_benefits"
        when "WCBPOL" then "workers_comp"
        when "AUTOPOL" then "auto_insurance"
        else "private_insurance"
        end
      end

      def self.extract_payor_name(fhir_hash)
        payors = fhir_hash[:payor] || fhir_hash["payor"]
        return nil unless payors&.any?
        payors.first[:display] || payors.first["display"]
      end

      def self.extract_period(fhir_hash)
        period = fhir_hash[:period] || fhir_hash["period"]
        return {} unless period
        {
          start_date: parse_date(period[:start] || period["start"]),
          end_date: parse_date(period[:end] || period["end"])
        }
      end

      def self.extract_class_info(fhir_hash)
        classes = fhir_hash[:class] || fhir_hash["class"]
        return {} unless classes

        result = {}
        classes.each do |cls|
          type_coding = cls[:type]&.dig(:coding, 0) || cls["type"]&.dig("coding", 0)
          code = type_coding&.dig(:code) || type_coding&.dig("code")

          case code
          when "group"
            result[:group_id] = cls[:value] || cls["value"]
          when "plan"
            result[:plan_name] = cls[:name] || cls["name"]
          when "rxid"
            result[:member_id] = cls[:value] || cls["value"]
          end
        end
        result
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
