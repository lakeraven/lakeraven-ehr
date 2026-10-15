# frozen_string_literal: true

module Lakeraven
  module EHR
    # Records psychotherapy visit coding against an open encounter.
    #
    # Only a resolved coding is written. An under-minimum visit or a
    # selection outside the documented band can still be stored through the
    # model (so finalization has a row to refuse); this service will not
    # record one, and it will not call RPMS unless the caller asked to
    # persist the procedure.
    class BehavioralHealthVisitCodingService
      Result = Struct.new(:success, :record, :claim_handoff, :error, :errors, keyword_init: true) do
        def success? = !!success
        def errors = self[:errors] || []
      end

      def initialize(patient_dfn:, encounter_ien:, encounter_kind:, duration_minutes:,
                     documented_by_duz:, selected_cpt_code: nil,
                     procedure_gateway: ProcedureGateway, persist_procedure: false)
        @patient_dfn = patient_dfn
        @encounter_ien = encounter_ien
        @encounter_kind = encounter_kind
        @duration_minutes = duration_minutes
        @documented_by_duz = documented_by_duz
        @selected_cpt_code = selected_cpt_code
        @procedure_gateway = procedure_gateway
        @persist_procedure = persist_procedure
      end

      def save
        record = build_record
        return refusal(record) unless record.valid? && record.resolved?

        record.save!
        return procedure_failure(record) if @persist_procedure && !write_procedure(record)

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

      def refusal(record)
        reason = record.blocking_reason
        Result.new(success: false, record: record, error: reason, errors: [ reason ].compact)
      end

      # RPMS procedure file write. Skipped entirely unless persist_procedure
      # was requested, so documenting a code does not open an RPC by itself.
      def write_procedure(record)
        raw = @procedure_gateway.add(@patient_dfn, @encounter_ien, record.cpt_code)
        raw.is_a?(Hash) && raw[:success]
      end

      def procedure_failure(record)
        Result.new(success: false, record: record, error: :procedure_write_failed, errors: [ :procedure_write_failed ])
      end
    end
  end
end
