# frozen_string_literal: true

module Lakeraven
  module EHR
    # Records psychotherapy visit coding against an open encounter.
    #
    # Only a resolved coding is written. An under-minimum visit or a
    # selection outside the documented band can still be stored through the
    # model (so finalization has a row to refuse); this service will not
    # record one. The service records the coding locally and returns the
    # claim handoff. It does not write to RPMS.
    class BehavioralHealthVisitCodingService
      Result = Struct.new(:success, :record, :claim_handoff, :error, :errors, keyword_init: true) do
        def success? = !!success
        def errors = self[:errors] || []
      end

      def initialize(patient_dfn:, encounter_ien:, encounter_kind:, duration_minutes:,
                     documented_by_duz:, selected_cpt_code: nil)
        @patient_dfn = patient_dfn
        @encounter_ien = encounter_ien
        @encounter_kind = encounter_kind
        @duration_minutes = duration_minutes
        @documented_by_duz = documented_by_duz
        @selected_cpt_code = selected_cpt_code
      end

      def save
        record = build_record
        return refusal(record) unless record.valid? && record.resolved?
        return already_recorded(record) unless save_record(record)

        Result.new(success: true, record: record, claim_handoff: record.to_claim_procedure_handoff, errors: [])
      end

      private

      def build_record
        BehavioralHealthVisitCoding.new(
          patient_dfn: @patient_dfn,
          encounter_ien: @encounter_ien,
          encounter_kind: @encounter_kind,
          duration_minutes: @duration_minutes,
          selected_cpt_code: @selected_cpt_code,
          documented_by_duz: @documented_by_duz
        )
      end

      # A hard block already names the reason. A row that fails validation
      # with no blocking reason (blank patient, encounter, or provider)
      # must still say why — a nil error is not a refusal the caller can show.
      def refusal(record)
        reason = record.blocking_reason
        if reason.nil?
          return Result.new(
            success: false,
            record: record,
            error: :invalid_input,
            errors: record.errors.full_messages
          )
        end

        Result.new(success: false, record: record, error: reason, errors: [ reason ])
      end

      # The unique index is the race boundary. The loser's insert rolls
      # back to this savepoint so the winner's row stays visible.
      def save_record(record)
        BehavioralHealthVisitCoding.transaction(requires_new: true) { record.save! }
        true
      rescue ActiveRecord::RecordNotUnique
        false
      end

      def already_recorded(record)
        Result.new(
          success: false,
          record: record,
          error: :coding_already_recorded,
          errors: [ :coding_already_recorded ]
        )
      end
    end
  end
end
