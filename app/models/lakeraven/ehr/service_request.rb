# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequest
      include ActiveModel::Model
      include ActiveModel::Attributes
      include FHIRSerializable

      attribute :ien, :integer
      attribute :patient_dfn, :integer
      attribute :identifier, :string
      attribute :referral_type, :string
      attribute :requesting_provider_ien, :integer
      attribute :performer_name, :string

      # Clinical fields (ported from the predecessor app)
      attribute :service_requested, :string
      attribute :reason_for_referral, :string
      attribute :urgency, :string
      attribute :status, :string
      attribute :estimated_cost, :float
      attribute :diagnosis_codes, :string
      attribute :procedure_codes, :string
      attribute :medical_priority_level, :integer

      # Validations (ported from the predecessor app)
      validates :patient_dfn, presence: true, numericality: { greater_than: 0 }
      validates :requesting_provider_ien, presence: true, numericality: { greater_than: 0 }
      validates :service_requested, presence: true
      validates :status, inclusion: { in: %w[active completed cancelled draft], allow_nil: true }
      validates :urgency, inclusion: { in: %w[ROUTINE URGENT EMERGENT], allow_nil: true }

      attribute :appointment_on, :date
      attribute :completed_on, :date
      attribute :notes, :string
      attribute :authored_on, :date

      class RecordNotFound < StandardError; end

      # -- Gateway DI --------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || ServiceRequestGateway
        end
      end

      def persisted?
        ien.present? && ien.to_i.positive?
      end

      # -- Status predicates ---------------------------------------------------

      def pending?
        status == "draft"
      end

      def active?
        status == "active"
      end

      def completed?
        status == "completed"
      end

      def cancelled?
        status == "cancelled"
      end

      # -- Business logic (ported from the predecessor app) -----------------------------

      def priority
        if emergent? then 1
        elsif urgent? then 2
        else 3
        end
      end

      def overdue?
        return false unless appointment_on.present?
        appointment_on < Date.current && !completed? && !cancelled?
      end

      def self.for_patient(dfn)
        gateway.for_patient(dfn)
      end

      # STATUS OF REFERRAL (#90001 .15): A ACTIVE, A1 APPROVED, C1
      # CLOSED-COMPLETED, X CLOSED-NOT COMPLETED. The search reply may carry
      # the code or its name, so both are read.
      # An RCIS REFERRAL (#90001) row, whatever its purpose.
      RCIS_REFERRAL = "rcis"
      # SNOMED CT 3457005 "Patient referral (procedure)": what every RCIS
      # referral is. US Core requires a code (1..1); the referral's purpose,
      # when RPMS has one, is its text.
      PATIENT_REFERRAL = { system: "http://snomed.info/sct", code: "3457005", display: "Patient referral" }.freeze

      RCIS_STATUS = {
        "A" => "active", "ACTIVE" => "active", "A1" => "active", "APPROVED" => "active",
        "C1" => "completed", "CLOSED-COMPLETED" => "completed",
        "X" => "cancelled", "CLOSED-NOT COMPLETED" => "cancelled"
      }.freeze

      # A row of RpmsRpc::Referral.for_patient (BMC SEARCH REFERRAL). Only
      # what has a FHIR element is kept: the row's HRN, patient name and
      # eligibility fields are not part of a ServiceRequest.
      def self.from_rpms_row(row, patient_dfn:)
        new(
          ien: row[:ien].to_s.presence,
          patient_dfn: patient_dfn.to_s,
          identifier: row[:referral_number].presence,
          status: RCIS_STATUS.fetch(row[:status].to_s.strip.upcase, "draft"),
          service_requested: row[:purpose].presence,
          referral_type: RCIS_REFERRAL,
          performer_name: row[:facility].presence,
          authored_on: row[:date]
        )
      end

      def self.create(attributes = {})
        new(attributes).tap(&:save)
      end

      def self.create!(attributes = {})
        new(attributes).tap(&:save!)
      end

      # -- Persistence -------------------------------------------------------

      def save
        return false unless valid?

        if persisted?
          true
        else
          result = self.class.gateway.register(persistable_attributes)
          if result[:success]
            self.ien = result[:ien]
            true
          else
            errors.add(:base, result[:error] || "Registration failed")
            false
          end
        end
      end

      def save!
        save || raise(ActiveModel::ValidationError.new(self))
      end

      # -- Urgency predicates ------------------------------------------------

      def emergent?
        urgency == "EMERGENT"
      end

      def urgent?
        urgency == "URGENT"
      end

      def routine?
        urgency.blank? || urgency == "ROUTINE"
      end

      # -- Class methods (FHIR) -----------------------------------------------

      def self.resource_class
        "ServiceRequest"
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          service_requested: fhir_resource.code&.text,
          reason_for_referral: fhir_resource.reasonCode&.first&.text,
          urgency: map_fhir_priority_to_urgency(fhir_resource.priority),
          status: map_fhir_status_to_status(fhir_resource.status)
        }
      end

      def self.map_fhir_priority_to_urgency(priority)
        case priority&.downcase
        when "urgent" then "URGENT"
        when "stat" then "EMERGENT"
        else "ROUTINE"
        end
      end

      def self.map_fhir_status_to_status(fhir_status)
        case fhir_status&.downcase
        when "active" then "active"
        when "completed" then "completed"
        when "cancelled", "revoked" then "cancelled"
        else "draft"
        end
      end

      # -- FHIR serialization ------------------------------------------------

      def to_fhir
        {
          resourceType: "ServiceRequest",
          id: ien&.to_s,
          identifier: build_fhir_identifiers,
          status: map_status_to_fhir,
          intent: "order",
          priority: map_urgency_to_fhir_priority,
          code: build_code,
          subject: patient_dfn ? build_reference("Patient", patient_dfn) : nil,
          authoredOn: authored_on&.iso8601,
          reasonCode: reason_for_referral.present? ? [ { text: reason_for_referral } ] : nil
        }.compact
      end

      private

      def persistable_attributes
        {
          patient_dfn: patient_dfn, requesting_provider_ien: requesting_provider_ien,
          service_requested: service_requested, reason_for_referral: reason_for_referral,
          urgency: urgency, status: status, referral_type: referral_type,
          performer_name: performer_name, identifier: identifier,
          estimated_cost: estimated_cost, diagnosis_codes: diagnosis_codes,
          procedure_codes: procedure_codes, medical_priority_level: medical_priority_level,
          appointment_on: appointment_on, completed_on: completed_on, notes: notes
        }.compact
      end

      def build_code
        if referral_type == RCIS_REFERRAL
          { coding: [ PATIENT_REFERRAL ], text: service_requested.presence }.compact
        elsif service_requested.present?
          { text: service_requested }
        end
      end

      def map_status_to_fhir
        if completed? then "completed"
        elsif cancelled? then "cancelled"
        else "active"
        end
      end

      def map_urgency_to_fhir_priority
        if emergent? || urgent? then "urgent"
        else "routine"
        end
      end

      def build_fhir_identifiers
        ids = []
        if ien.present?
          ids << { use: "official" }.merge(build_identifier(system: "http://ihs.gov/rpms/consult-id", value: ien))
        end
        if identifier.present?
          ids << { use: "usual" }.merge(
            build_identifier(system: "http://ihs.gov/rpms/service-request-identifier", value: identifier)
          )
        end
        ids.presence
      end
    end
  end
end
