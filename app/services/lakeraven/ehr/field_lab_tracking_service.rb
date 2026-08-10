# frozen_string_literal: true

module Lakeraven
  module EHR
    # FieldLabTrackingService -- create and advance the screening →
    # confirmation → treatment arc for field encounters, and surface the
    # confirmation/treatment drop-off as a work queue (#418).
    #
    # This service also implements the FieldSyncService *handler* protocol
    # (#create, #find, #version_of, #apply) so synced field-lab operations from
    # an offline iPad reconcile through the same server-authoritative path as
    # everything else. Keeping the protocol here (not in the sync service) keeps
    # clinical stage logic in one place.
    #
    # RPMS/RPC write-back of these records is intentionally out of scope for the
    # first pass; the arc is persisted durably in the engine and write-back is a
    # tracked follow-up (mirrors the reconciliation_items write_back pattern).
    class FieldLabTrackingService
      TARGET_TYPE = "FieldLabTracking"

      class UnknownAction < StandardError; end

      # -- Clinical entry points ---------------------------------------------

      # Record a field screening, opening a tracking record.
      def screen(patient_ref:, condition: nil, screening_test: nil,
                 screening_result: nil, screening_recorded_at: nil,
                 site_ien: nil, clinician_duz: nil, encounter_ref: nil, details: {})
        FieldLabTrackingRecord.create!(
          patient_ref: patient_ref,
          condition: condition,
          screening_test: screening_test,
          screening_result: screening_result,
          screening_recorded_at: screening_recorded_at || Time.current,
          site_ien: site_ien,
          clinician_duz: clinician_duz,
          encounter_ref: encounter_ref,
          details: details || {},
          stage: "screened",
          version: 1
        )
      end

      # Records that still need a confirmation result or treatment — the
      # follow-up list that attacks the 30–35% drop-off. Minimal fields, in the
      # spirit of the #399 work-queue surface.
      def work_queue(site_ien: nil, patient_ref: nil)
        scope = FieldLabTrackingRecord.open_stage
        scope = scope.for_site(site_ien) if site_ien.present?
        scope = scope.for_patient(patient_ref) if patient_ref.present?

        scope.order(updated_at: :asc).select(&:awaiting).map do |rec|
          {
            id: rec.id,
            patient_ref: rec.patient_ref,
            condition: rec.condition,
            stage: rec.stage,
            awaiting: rec.awaiting,
            screening_result: rec.screening_result,
            site_ien: rec.site_ien
          }
        end
      end

      # -- FieldSyncService handler protocol ---------------------------------

      # create(op) -> record. `op` is a normalized sync operation whose :payload
      # carries the screening capture.
      def create(op)
        p = op.payload
        screen(
          patient_ref: p[:patient_ref],
          condition: p[:condition],
          screening_test: p[:screening_test],
          screening_result: p[:screening_result],
          screening_recorded_at: p[:screening_recorded_at] || op.client_recorded_at,
          site_ien: p[:site_ien] || op.site_ien,
          clinician_duz: p[:clinician_duz] || op.clinician_duz,
          encounter_ref: p[:encounter_ref],
          details: p[:details] || {}
        )
      end

      def find(target_id)
        FieldLabTrackingRecord.find_by(id: target_id)
      end

      def version_of(record)
        record.version
      end

      # apply(record, op) -> record. Advances the arc per payload[:action].
      # Raises on an unknown action so a malformed sync payload fails loudly
      # rather than being silently dropped.
      def apply(record, op)
        p = op.payload
        case p[:action].to_s
        when "order_confirmation"
          record.order_confirmation!(
            loinc: p[:confirmation_loinc],
            order_ref: p[:confirmation_order_ref],
            ordered_at: p[:confirmation_ordered_at] || op.client_recorded_at || Time.current,
            by_duz: p[:clinician_duz] || op.clinician_duz
          )
        when "record_confirmation_result"
          record.record_confirmation_result!(
            status: p[:confirmation_result_status],
            value: p[:confirmation_result_value],
            resulted_at: p[:confirmation_resulted_at] || op.client_recorded_at || Time.current
          )
        when "start_treatment"
          record.start_treatment!(
            medication: p[:treatment_medication],
            started_at: p[:treatment_started_at] || op.client_recorded_at || Time.current,
            by_duz: p[:clinician_duz] || op.clinician_duz
          )
        when "mark_lost_to_followup"
          record.mark_lost_to_followup!(reason: p[:reason])
        else
          raise UnknownAction, "unknown field-lab action #{p[:action].inspect}"
        end

        record
      end
    end
  end
end
