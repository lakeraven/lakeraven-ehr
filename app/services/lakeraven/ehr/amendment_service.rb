# frozen_string_literal: true

module Lakeraven
  module EHR
    # AmendmentService — orchestrates patient health record amendment workflow.
    # ONC § 170.315(d)(4) — Amendments
    # HIPAA § 164.526 — Right of Amendment
    class AmendmentService
      class << self
        def request(patient_dfn:, resource_type:, description:, reason:, requested_by: nil)
          amendment = AmendmentRequest.create!(
            patient_dfn: patient_dfn,
            resource_type: resource_type,
            description: description,
            reason: reason,
            requested_by: requested_by || patient_dfn,
            status: "pending"
          )

          AuditEvent.create!(
            event_type: "application",
            action: "C",
            outcome: "0",
            agent_who_type: "Patient",
            agent_who_identifier: patient_dfn,
            entity_id: amendment.id.to_s,
            entity_type: "AmendmentRequest",
            entity_identifier: amendment.id.to_s,
            outcome_desc: "Amendment requested for patient #{patient_dfn}"
          )

          amendment
        end

        def accept(amendment, reviewer_duz:, reason: nil)
          amendment.accept!(reviewer_duz: reviewer_duz, reason: reason)
        end

        def deny(amendment, reviewer_duz:, reason:)
          amendment.deny!(reviewer_duz: reviewer_duz, reason: reason)
        end

        def history(patient_dfn)
          AmendmentRequest.for_patient(patient_dfn).reverse_chronological
        end

        def pending_reviews
          AmendmentRequest.pending_review
        end
      end
    end
  end
end
