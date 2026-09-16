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
      # FHIR resource id (optional; mirrors Provenance#fhir_id). Set when the
      # encounter has no numeric IEN — appointment-derived encounters carry a
      # deterministic derived id, fixture encounters a seeded one — so
      # ids/fullUrls stay stable across requests. Wins over `ien` in to_fhir.
      attribute :fhir_id, :string
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
      attribute :service_provider_organization_ien, :integer

      # Array attribute — not natively typed by ActiveModel, use plain accessor
      attr_accessor :participant_practitioner_iens

      validates :status, inclusion: { in: VALID_STATUSES }
      validates :class_code, inclusion: { in: VALID_CLASS_CODES }

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || EncounterGateway
        end
      end

      def self.for_patient(dfn)
        gateway.for_patient(dfn)
      end

      # RPMS appointment external statuses (ORWPT APPTLST piece 4) to FHIR
      # Encounter.status. Unrecognized wire statuses map to "unknown" (a
      # legal FHIR code) rather than being invented. "INPATIENT" on an
      # appointment row says the patient was ADMITTED around that visit — it
      # does not say the admission is still under way, so it maps to
      # "unknown", never to "in-progress" (asserting an active encounter for
      # a possibly long-past admission would fabricate clinical state).
      APPOINTMENT_STATUS_MAP = {
        "FUTURE" => "planned",
        "SCHEDULED" => "planned",
        "CHECKED IN" => "arrived",
        "CHECKED OUT" => "finished",
        "INPATIENT" => "unknown",
        "NO-SHOW" => "cancelled",
        "NO SHOW" => "cancelled",
        "CANCELLED" => "cancelled"
      }.freeze

      # Encounter.class derives from the actual setting the wire reports:
      # an INPATIENT row is an inpatient encounter (IMP); everything else on
      # the appointment list is a clinic appointment (AMB).
      APPOINTMENT_CLASS_MAP = {
        "INPATIENT" => "IMP"
      }.freeze
      APPOINTMENT_DEFAULT_CLASS = "AMB"

      # Build Encounter instances from raw ORWPT APPTLST appointment hashes
      # ({ datetime:, location_ien:, location:, status: }).
      #
      # The wire carries no IEN, so the id derives DETERMINISTICALLY from
      # dfn + appointment timestamp (mirroring Observation.vital_id) — never
      # a random uuid.
      def self.from_appointment_hashes(hashes, patient_dfn:)
        Array(hashes).map do |h|
          wire_status = h[:status].to_s.upcase
          # Both owner fields carry the SAME patient (see #owner_patient_id).
          new(
            fhir_id: appointment_id(patient_dfn, h),
            patient_identifier: patient_dfn.to_s,
            patient_dfn: patient_dfn,
            status: APPOINTMENT_STATUS_MAP[wire_status] || "unknown",
            class_code: APPOINTMENT_CLASS_MAP.fetch(wire_status, APPOINTMENT_DEFAULT_CLASS),
            period_start: h[:datetime],
            location_ien: h[:location_ien]
          )
        end
      end

      def self.appointment_id(patient_dfn, hash)
        id = "appt-#{patient_dfn}"
        datetime = hash[:datetime]
        id += "-#{datetime.strftime('%Y%m%d%H%M')}" if datetime.respond_to?(:strftime)
        id
      end
      private_class_method :appointment_id

      # -- Ownership -----------------------------------------------------------

      # The ONE patient this encounter belongs to. `patient_identifier` (the
      # FHIR subject id, set by the appointment path and fixture seeds) wins;
      # `patient_dfn` is the fallback for records built with only the RPMS
      # DFN. Every place ownership matters — store search, the FHIR subject
      # reference, show authorization — keys on this value, so a record can
      # never surface in one patient's search while referencing another
      # (adversarial review finding: the two fields used to compete).
      def owner_patient_id
        (patient_identifier.presence || patient_dfn)&.to_s
      end

      # -- Display helpers ---------------------------------------------------

      def status_display = STATUS_DISPLAY[status]
      def class_display = CLASS_DISPLAY[class_code]

      # -- Status predicates -------------------------------------------------

      def in_progress? = status == "in-progress"
      def finished? = status == "finished"
      def cancelled? = status == "cancelled"
      def planned? = status == "planned"
      def arrived? = status == "arrived"

      # -- Class predicates --------------------------------------------------

      def ambulatory? = class_code == "AMB"
      def emergency? = class_code == "EMER"
      def inpatient? = class_code == "IMP"
      def virtual? = class_code == "VR"

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

      # -- Period helpers ----------------------------------------------------

      def within_period?
        now = DateTime.current
        start_ok = period_start.nil? || period_start <= now
        end_ok = period_end.nil? || period_end >= now
        start_ok && end_ok
      end

      # -- FHIR serialization ------------------------------------------------

      US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-encounter"
      ACT_CODE_SYSTEM = "http://terminology.hl7.org/CodeSystem/v3-ActCode"

      def to_fhir
        resource = {
          resourceType: "Encounter",
          meta: { profile: [ US_CORE_PROFILE ] },
          status: status,
          class: { system: ACT_CODE_SYSTEM, code: class_code, display: class_display }.compact
        }

        resource[:id] = fhir_id.presence || ien&.to_s
        resource.delete(:id) if resource[:id].blank?
        resource[:period] = build_period if period_start || period_end
        # Omit `coding` (never emit "code": null) when only display text exists.
        resource[:type] = [ { text: type_display, coding: type_code ? [ { code: type_code } ] : nil }.compact ] if type_display
        resource[:reasonCode] = [ { text: reason_display, coding: reason_code ? [ { code: reason_code } ] : nil }.compact ] if reason_display
        owner = owner_patient_id
        resource[:subject] = { reference: "Patient/#{owner}" } if owner
        if practitioner_identifier
          resource[:participant] = [ { individual: { reference: "Practitioner/#{practitioner_identifier}" } } ]
        elsif participant_practitioner_iens.is_a?(Array) && participant_practitioner_iens.any?
          resource[:participant] = participant_practitioner_iens.map do |ien|
            { individual: { reference: "Practitioner/rpms-practitioner-#{ien}" } }
          end
        end

        if location_ien
          resource[:location] = [ { location: { reference: "Location/rpms-location-#{location_ien}" } } ]
        end

        if service_provider_organization_ien
          resource[:serviceProvider] = { reference: "Organization/rpms-organization-#{service_provider_organization_ien}" }
        end

        resource
      end

      def self.resource_class
        "Encounter"
      end

      # -- FHIR deserialization ----------------------------------------------

      def self.from_fhir_attributes(fhir)
        attrs = { status: fhir[:status] }
        attrs[:class_code] = fhir.dig(:class, :code) if fhir.dig(:class, :code)
        if fhir.dig(:subject, :reference)&.include?("Patient/")
          attrs[:patient_identifier] = fhir.dig(:subject, :reference).split("/").last
        end
        attrs
      end

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
