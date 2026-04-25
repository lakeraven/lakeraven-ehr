# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequest
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :integer
      attribute :patient_dfn, :integer
      attribute :identifier, :string
      attribute :referral_type, :string
      attribute :requesting_provider_ien, :integer
      attribute :performer_name, :string

      # Clinical fields (ported from rpms_redux)
      attribute :service_requested, :string
      attribute :reason_for_referral, :string
      attribute :urgency, :string
      attribute :status, :string
      attribute :estimated_cost, :float
      attribute :diagnosis_codes, :string
      attribute :procedure_codes, :string
      attribute :medical_priority_level, :integer

      # Validations (ported from rpms_redux)
      validates :patient_dfn, presence: true, numericality: { greater_than: 0 }
      validates :requesting_provider_ien, presence: true, numericality: { greater_than: 0 }
      validates :service_requested, presence: true
      validates :status, inclusion: { in: %w[active completed cancelled draft], allow_nil: true }
      validates :urgency, inclusion: { in: %w[ROUTINE URGENT EMERGENT], allow_nil: true }

      attribute :appointment_on, :date
      attribute :completed_on, :date
      attribute :notes, :string

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

      # -- Business logic (ported from rpms_redux) -----------------------------

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
          code: service_requested.present? ? { text: service_requested } : nil,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
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
        ids << { use: "official", system: "http://ihs.gov/rpms/consult-id", value: ien.to_s } if ien.present?
        ids << { use: "usual", system: "http://ihs.gov/rpms/service-request-identifier", value: identifier } if identifier.present?
        ids.presence
      end
    end
  end
end
