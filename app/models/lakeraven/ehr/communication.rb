# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR Communication resource - ActiveModel (RPC-backed)
    # Manages secure messages between care team members.
    class Communication
      include ActiveModel::Model
      include ActiveModel::Attributes

      # Communication status codes (FHIR R4)
      STATUSES = {
        "preparation" => "Preparation",
        "in-progress" => "In Progress",
        "not-done" => "Not Done",
        "on-hold" => "On Hold",
        "stopped" => "Stopped",
        "completed" => "Completed",
        "entered-in-error" => "Entered in Error",
        "unknown" => "Unknown"
      }.freeze

      # Communication priority codes (FHIR R4)
      PRIORITIES = {
        "routine" => "Routine",
        "urgent" => "Urgent",
        "asap" => "ASAP",
        "stat" => "Stat"
      }.freeze

      # Communication category codes
      CATEGORIES = {
        "alert" => "Alert",
        "notification" => "Notification",
        "reminder" => "Reminder",
        "instruction" => "Instruction"
      }.freeze

      # -- Attributes ----------------------------------------------------------

      attribute :ien, :string
      attribute :subject_patient_dfn, :string
      attribute :sender_type, :string
      attribute :sender_id, :string
      attribute :recipient_type, :string
      attribute :recipient_id, :string
      attribute :payload_content, :string
      attribute :status, :string
      attribute :priority, :string
      attribute :category, :string
      attribute :sent, :datetime
      attribute :thread_id, :string
      attribute :parent_message_id, :string
      attribute :rpms_message_id, :string
      attribute :rpms_parent_id, :string
      attribute :about_service_request_ien, :string
      attribute :encounter_id, :string

      # -- Validations ---------------------------------------------------------

      validates :subject_patient_dfn, presence: true
      validates :sender_id, presence: true
      validates :payload_content, presence: true
      validates :status, inclusion: { in: STATUSES.keys }, allow_blank: true
      validates :priority, inclusion: { in: PRIORITIES.keys }, allow_blank: true
      validates :category, inclusion: { in: CATEGORIES.keys }, allow_blank: true

      # -- Persistence ---------------------------------------------------------

      def persisted?
        ien.present?
      end

      # -- Status helpers ------------------------------------------------------

      def draft?          = status == "preparation"
      def in_progress?    = status == "in-progress"
      def completed?      = status == "completed"
      def on_hold?        = status == "on-hold"
      def stopped?        = status == "stopped"
      def status_display  = STATUSES[status] || "Unknown"

      # -- Priority helpers ----------------------------------------------------

      def routine?         = priority == "routine"
      def urgent?          = priority == "urgent"
      def asap?            = priority == "asap"
      def stat?            = priority == "stat"
      def priority_display = PRIORITIES[priority] || "Unknown"

      # -- Category helpers ----------------------------------------------------

      def category_display = CATEGORIES[category] || "Unknown"
      def alert?           = category == "alert"
      def notification?    = category == "notification"
      def reminder?        = category == "reminder"
      def instruction?     = category == "instruction"

      # -- Threading helpers ---------------------------------------------------

      def root_message?
        parent_message_id.nil?
      end

      def reply?
        parent_message_id.present?
      end

      # -- FHIR serialization (hash-based) -------------------------------------

      def to_fhir
        resource = {
          resourceType: "Communication",
          status: status,
          priority: priority,
          subject: subject_patient_dfn.present? ? { reference: "Patient/#{subject_patient_dfn}" } : nil,
          sender: build_sender_reference,
          recipient: build_recipient_references,
          payload: build_fhir_payload,
          category: build_fhir_category,
          sent: sent&.iso8601
        }
        resource[:id] = ien.to_s if ien.present?
        resource
      end

      def self.resource_class
        "Communication"
      end

      def self.from_fhir(fhir_resource)
        new(from_fhir_attributes(fhir_resource))
      end

      def self.from_fhir_attributes(fhir_resource)
        attrs = { status: fhir_resource.status }

        if fhir_resource.respond_to?(:subject) && fhir_resource.subject&.reference.present?
          ref = fhir_resource.subject.reference
          if ref.include?("Patient/")
            dfn = ref.split("/").last.gsub(/\D/, "")
            attrs[:subject_patient_dfn] = dfn if dfn.present?
          end
        end

        if fhir_resource.respond_to?(:sender) && fhir_resource.sender&.reference.present?
          ref = fhir_resource.sender.reference
          if ref.include?("/")
            parts = ref.split("/")
            attrs[:sender_type] = parts[0]
            attrs[:sender_id] = parts[1]
          end
        end

        if fhir_resource.respond_to?(:payload) && fhir_resource.payload&.any?
          attrs[:payload_content] = fhir_resource.payload.first.contentString
        end

        attrs
      end

      private

      def build_sender_reference
        return nil unless sender_type.present? && sender_id.present?
        { reference: "#{sender_type}/#{sender_id}" }
      end

      def build_recipient_references
        return [] unless recipient_type.present? && recipient_id.present?
        [ { reference: "#{recipient_type}/#{recipient_id}" } ]
      end

      def build_fhir_payload
        return [] if payload_content.blank?
        [ { contentString: payload_content } ]
      end

      def build_fhir_category
        return [] if category.blank?
        [ {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/communication-category",
            code: category,
            display: category_display
          } ]
        } ]
      end
    end
  end
end
