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
          subscriberId: member_identifier,
          identifier: member_identifier_list,
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

        new(eligibility_attributes(response)).tap { |coverage| assign_medicaid_payor(coverage) }
      end

      def self.eligibility_attributes(response)
        {
          patient_dfn: response.patient_dfn,
          coverage_type: response.coverage_type,
          status: "active",
          start_date: response.start_date,
          end_date: response.end_date,
          plan_name: response.plan_name,
          member_id: response.policy_id,
          group_id: response.group_id
        }
      end

      def self.assign_medicaid_payor(coverage)
        coverage.payor_name = "Medicaid" if coverage.medicaid?
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

      def member_identifier
        member_id.presence || subscriber_id.presence
      end

      def member_identifier_list
        value = member_identifier
        [ { value: value } ] if value
      end

      def build_class_array
        [ group_fhir_class, plan_fhir_class ].compact.presence
      end

      def group_fhir_class
        return if group_id.blank?

        { type: fhir_class_type("group"), value: group_id }
      end

      # R4 Coverage.class (plan).value is the plan identifier; .name is the plan name.
      # Member id is subscriberId, never this value.
      def plan_fhir_class
        value = plan_id.presence || plan_name.presence
        return unless value

        { type: fhir_class_type("plan"), value: value, name: plan_name.presence }.compact
      end

      def fhir_class_type(code)
        { coding: [ { code: code } ] }
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
        result = {}
        Array(fhir_hash[:class] || fhir_hash["class"]).each { |cls| assign_class_field(result, cls) }
        assign_member_id(result, fhir_hash)
        result
      end

      def self.assign_class_field(result, cls)
        value = cls[:value] || cls["value"]
        case fhir_class_code(cls)
        when "group" then result[:group_id] = value
        when "plan" then assign_plan_class(result, cls, value)
        when "rxid" then result[:member_id] = value
        end
      end

      def self.assign_plan_class(result, cls, value)
        name = cls[:name] || cls["name"]
        result[:plan_name] = name if name.present?
        result[:plan_id] = value if value.present? && value != name
      end

      def self.assign_member_id(result, fhir_hash)
        subscriber_id = fhir_hash[:subscriberId] || fhir_hash["subscriberId"]
        result[:member_id] = subscriber_id if subscriber_id.present?
      end

      def self.fhir_class_code(cls)
        coding = cls[:type]&.dig(:coding, 0) || cls["type"]&.dig("coding", 0)
        coding&.dig(:code) || coding&.dig("code")
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
