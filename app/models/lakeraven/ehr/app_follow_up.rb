# frozen_string_literal: true

module Lakeraven
  module EHR
    # Demo prototype (#988, #989, #990; not in the December build, synthetic
    # data only). What a registered outside app learned about a referral,
    # posted as a FHIR Communication and held for a person to confirm or
    # reject. Only a confirmed follow-up is written to RPMS (ReferralFollowUpWriteBack).
    class AppFollowUp < ApplicationRecord
      self.table_name = "lakeraven_ehr_app_follow_ups"

      STATUSES = %w[pending confirmed rejected].freeze
      SUMMARY_LIMIT = 500
      EXTENSION = "https://lakeraven.com/fhir/StructureDefinition/referral-follow-up"
      AI_TAG = { system: "http://terminology.hl7.org/CodeSystem/v3-ObservationValue", code: "AIAST",
                 display: "Artificial Intelligence asserted" }.freeze

      validates :client_id, :app_name, presence: true
      validates :patient_dfn, :referral_ien, numericality: { only_integer: true, greater_than: 0 }
      validates :status, inclusion: { in: STATUSES }
      validates :summary, presence: true, length: { maximum: SUMMARY_LIMIT }

      scope :pending, -> { where(status: "pending").order(:created_at) }
      scope :reviewed, -> { where.not(status: "pending").order(reviewed_at: :desc) }

      def pending? = status == "pending"
      def confirmed? = status == "confirmed"
      def rejected? = status == "rejected"
      def written_back? = write_back_status == "written"
      def write_back_failed? = write_back_status == "failed"

      # The note filed on the RPMS referral when this is confirmed. Says where
      # it came from and who confirmed it, so the record never reads as a
      # clinician's own words.
      def case_note
        source = ai_generated ? "AI-generated, " : ""
        when_text = appointment_on ? " Appointment #{appointment_on.strftime('%m/%d/%Y')}." : ""
        "Outside app #{app_name} (#{source}confirmed by #{reviewed_by_name}): #{summary}#{when_text}"
      end

      def to_fhir
        {
          resourceType: "Communication",
          id: id.to_s,
          meta: ai_generated ? { tag: [ AI_TAG ] } : nil,
          status: fhir_status,
          statusReason: rejected? ? { text: "Rejected in staff review" } : nil,
          subject: { reference: "Patient/#{patient_dfn}" },
          about: [ { reference: "ServiceRequest/#{FHIR::PatientScopedId.build(patient_dfn, referral_ien)}" } ],
          sender: { reference: "Device/#{client_id}", display: app_name },
          sent: created_at&.iso8601,
          payload: [ { contentString: summary } ],
          extension: [ { url: EXTENSION, extension: follow_up_extensions } ]
        }.compact
      end

      private

      # Held for review is in-progress (#988); confirmed is completed; a
      # rejected one is not-done, which the app can read back (#989).
      def fhir_status
        { "pending" => "in-progress", "confirmed" => "completed", "rejected" => "not-done" }.fetch(status)
      end

      def follow_up_extensions
        [
          reached.nil? ? nil : { url: "reached", valueBoolean: reached },
          appointment_on ? { url: "appointmentDate", valueDate: appointment_on.iso8601 } : nil
        ].compact
      end
    end
  end
end
