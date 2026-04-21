# frozen_string_literal: true

module Lakeraven
  module EHR
    class Encounter
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_STATUSES = %w[planned arrived triaged in-progress onleave finished cancelled entered-in-error unknown].freeze
      VALID_CLASS_CODES = %w[AMB EMER FLD HH IMP ACUTE NONAC OBSENC PRENC SS VR].freeze

      STATUS_DISPLAY = {
        "planned" => "Planned", "arrived" => "Arrived", "triaged" => "Triaged",
        "in-progress" => "In Progress", "onleave" => "On Leave", "finished" => "Finished",
        "cancelled" => "Cancelled", "entered-in-error" => "Entered in Error", "unknown" => "Unknown"
      }.freeze

      CLASS_DISPLAY = {
        "AMB" => "Ambulatory", "EMER" => "Emergency", "FLD" => "Field",
        "HH" => "Home Health", "IMP" => "Inpatient", "ACUTE" => "Inpatient Acute",
        "NONAC" => "Inpatient Non-Acute", "OBSENC" => "Observation",
        "PRENC" => "Pre-Admission", "SS" => "Short Stay", "VR" => "Virtual"
      }.freeze

      attribute :ien, :integer
      attribute :status, :string
      attribute :class_code, :string
      attribute :period_start, :datetime
      attribute :period_end, :datetime
      attribute :type_code, :string
      attribute :type_display, :string
      attribute :reason_code, :string
      attribute :reason_display, :string
      attribute :patient_identifier, :string
      attribute :practitioner_identifier, :string
      attribute :patient_dfn, :integer
      attribute :location_ien, :integer

      validates :status, inclusion: { in: VALID_STATUSES }
      validates :class_code, inclusion: { in: VALID_CLASS_CODES }

      # -- Display helpers ---------------------------------------------------

      def status_display = STATUS_DISPLAY[status]
      def class_display = CLASS_DISPLAY[class_code]

      # -- Status predicates -------------------------------------------------

      def in_progress? = status == "in-progress"
      def finished? = status == "finished"
      def cancelled? = status == "cancelled"
      def planned? = status == "planned"

      # -- Class predicates --------------------------------------------------

      def ambulatory? = class_code == "AMB"
      def emergency? = class_code == "EMER"
      def inpatient? = class_code == "IMP"

      # -- Workflow methods --------------------------------------------------

      # Close an encounter. Sets status to finished, records end time.
      # Returns false if already finished.
      def close(reason_code: nil, reason_display: nil)
        if finished?
          errors.add(:status, "already finished")
          return false
        end

        self.status = "finished"
        self.period_end = DateTime.current
        self.reason_code = reason_code if reason_code
        self.reason_display = reason_display if reason_display
        true
      end

      # Cancel a planned encounter.
      def cancel
        self.status = "cancelled"
      end

      # -- FHIR serialization ------------------------------------------------

      US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-encounter"
      ACT_CODE_SYSTEM = "http://terminology.hl7.org/CodeSystem/v3-ActCode"

      def to_fhir
        resource = {
          resourceType: "Encounter",
          meta: { profile: [ US_CORE_PROFILE ] },
          status: status,
          class: { system: ACT_CODE_SYSTEM, code: class_code, display: class_display }
        }

        resource[:id] = ien.to_s if ien
        resource[:period] = build_period if period_start || period_end
        resource[:type] = [ { text: type_display, coding: [ { code: type_code } ] } ] if type_display
        resource[:reasonCode] = [ { text: reason_display, coding: [ { code: reason_code } ] } ] if reason_display
        resource[:subject] = { reference: "Patient/#{patient_identifier}" } if patient_identifier
        if practitioner_identifier
          resource[:participant] = [ { individual: { reference: "Practitioner/#{practitioner_identifier}" } } ]
        end

        resource
      end

      # -- FHIR deserialization ----------------------------------------------

      def self.from_fhir(fhir)
        new(
          status: fhir[:status],
          class_code: fhir.dig(:class, :code),
          period_start: fhir.dig(:period, :start) ? DateTime.parse(fhir.dig(:period, :start)) : nil,
          period_end: fhir.dig(:period, :end) ? DateTime.parse(fhir.dig(:period, :end)) : nil
        )
      end

      def to_param = ien.to_s

      private

      def build_period
        p = {}
        p[:start] = period_start.iso8601 if period_start
        p[:end] = period_end.iso8601 if period_end
        p
      end
    end
  end
end
