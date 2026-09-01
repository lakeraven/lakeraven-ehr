# frozen_string_literal: true

module Lakeraven
  module EHR
    # FieldLabTrackingRecord -- the screening → confirmation → treatment spine
    # for street-medicine field encounters (#418).
    #
    # Two tribal programs (Cherokee Nation HELP, Sih Hasin) independently lost
    # 65–70% of reactive screens between the field and confirmation/treatment.
    # This record keeps that whole arc in ONE row so the drop-off is a queryable
    # follow-up item, not a paper "green book" entry that never round-trips.
    #
    # Stage is server-authoritative and advanced only through the guarded
    # transitions below (no AASM — this is remote-owned clinical state; each
    # transition bumps #version for the sync-conflict check in FieldSyncService).
    class FieldLabTrackingRecord < ApplicationRecord
      self.table_name = "lakeraven_ehr_field_lab_tracking_records"

      STAGES = %w[
        screened confirmation_ordered confirmed indeterminate negative treated lost_to_followup
      ].freeze

      SCREENING_RESULTS = %w[reactive nonreactive indeterminate].freeze
      CONFIRMATION_STATUSES = %w[positive negative indeterminate].freeze

      TERMINAL_STAGES = %w[treated negative lost_to_followup].freeze

      validates :patient_ref, presence: true
      validates :stage, inclusion: { in: STAGES }
      validates :screening_result, inclusion: { in: SCREENING_RESULTS }, allow_nil: true
      validates :confirmation_result_status, inclusion: { in: CONFIRMATION_STATUSES }, allow_nil: true
      validates :version, numericality: { greater_than: 0 }

      scope :for_patient, ->(ref) { where(patient_ref: ref) }
      scope :for_site, ->(ien) { where(site_ien: ien) }
      scope :reactive, -> { where(screening_result: "reactive") }
      scope :open_stage, -> { where.not(stage: TERMINAL_STAGES) }

      # -- Stage predicates --------------------------------------------------

      def screened? = stage == "screened"
      def confirmation_ordered? = stage == "confirmation_ordered"
      def confirmed? = stage == "confirmed"
      def treated? = stage == "treated"
      def lost_to_followup? = stage == "lost_to_followup"
      def terminal? = TERMINAL_STAGES.include?(stage)

      # A reactive screen that has not yet reached a confirmation *result*.
      # This is the primary drop-off the field program is trying to close.
      def awaiting_confirmation?
        screening_result == "reactive" &&
          %w[screened confirmation_ordered].include?(stage) &&
          confirmation_resulted_at.blank?
      end

      # Confirmed positive but treatment not yet started.
      def awaiting_treatment? = confirmed?

      # An indeterminate confirmation result is clinically unresolved: the
      # patient still needs a repeat confirmation, so they stay on the queue
      # rather than dropping off as a false "negative" terminal.
      def awaiting_reconfirmation? = stage == "indeterminate"

      # What this record is currently waiting on, for the work queue.
      def awaiting
        return "confirmation" if awaiting_confirmation?
        return "reconfirmation" if awaiting_reconfirmation?
        return "treatment" if awaiting_treatment?

        nil
      end

      # -- Guarded transitions -----------------------------------------------
      # Each raises on an illegal transition so a bad sync payload fails loudly
      # rather than silently corrupting the arc.

      class IllegalTransition < StandardError; end

      def order_confirmation!(loinc:, order_ref: nil, ordered_at: Time.current, by_duz: nil)
        # Orderable from a fresh reactive screen, or to re-confirm after an
        # indeterminate result (which is unresolved, not terminal).
        unless %w[screened indeterminate].include?(stage) && screening_result == "reactive"
          raise IllegalTransition, "cannot order confirmation from stage=#{stage}, screening=#{screening_result.inspect}"
        end

        update!(
          stage: "confirmation_ordered",
          confirmation_loinc: loinc,
          confirmation_order_ref: order_ref,
          confirmation_ordered_at: ordered_at,
          clinician_duz: by_duz || clinician_duz,
          version: version + 1
        )
      end

      def record_confirmation_result!(status:, value: nil, resulted_at: Time.current)
        unless stage == "confirmation_ordered"
          raise IllegalTransition, "cannot record confirmation result from stage=#{stage}"
        end
        unless CONFIRMATION_STATUSES.include?(status.to_s)
          raise IllegalTransition, "unknown confirmation status #{status.inspect}"
        end

        # positive → confirmed (treat); negative → terminal negative;
        # indeterminate → unresolved, kept on the follow-up queue for a repeat
        # draw (never finalized as a false negative).
        next_stage = case status.to_s
        when "positive" then "confirmed"
        when "indeterminate" then "indeterminate"
        else "negative"
        end
        update!(
          stage: next_stage,
          confirmation_result_status: status.to_s,
          confirmation_result_value: value,
          confirmation_resulted_at: resulted_at,
          version: version + 1
        )
      end

      def start_treatment!(medication:, started_at: Time.current, by_duz: nil)
        unless stage == "confirmed"
          raise IllegalTransition, "cannot start treatment from stage=#{stage}"
        end

        update!(
          stage: "treated",
          treatment_medication: medication,
          treatment_started_at: started_at,
          clinician_duz: by_duz || clinician_duz,
          version: version + 1
        )
      end

      def mark_lost_to_followup!(reason: nil)
        raise IllegalTransition, "record already terminal (#{stage})" if terminal?

        merged = details.merge("lost_reason" => reason).compact
        update!(stage: "lost_to_followup", details: merged, version: version + 1)
      end
    end
  end
end
