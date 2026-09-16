# frozen_string_literal: true

module Lakeraven
  module EHR
    class AuditEventsController < ApplicationController
      include PatientCompartment

      # AuditEvent IS the accounting-of-disclosures record: which patients a
      # facility touched, by whom, from where. Unbound, it handed a token bound
      # to patient 999 the access trail of every other patient — the same
      # defect class as `?patient=1`, on the one endpoint whose whole purpose
      # is disclosure.
      #
      # DECISION: bind it rather than forbid it. A patient has a right to an
      # accounting of disclosures about THEMSELVES (HIPAA §164.528), so a
      # patient-context token may read its own compartment's trail and only
      # that. Unbound (user/ or system/) tokens — the compliance-officer case —
      # are unaffected.
      # Only #index takes a patient parameter; #show is bound by the row filter
      # below, which is the authoritative check either way — the binding
      # governs which ROWS come back, not merely which patient is named.
      compartment_bound :index, param: :patient

      def index
        render_bundle(scoped_events.recent.limit(100).map(&:to_fhir))
      end

      def show
        event = scoped_events.find_by(id: params[:id])
        if event
          render_fhir(event.to_fhir)
        else
          render_not_found("AuditEvent", params[:id])
        end
      end

      private

      # FHIR type these rows are attributed to for a patient. Audit writes set
      # entity_type from the accessed resource's FHIR type, so a row directly
      # about a patient carries "Patient".
      PATIENT_ENTITY_TYPE = "Patient"

      # A patient-bound token sees only rows PROVABLY about its own patient.
      #
      # entity_identifier is a promiscuous column — patient DFNs, amendment
      # ids, encounter iens and class names all live in it — so keying on the
      # value alone let foreign-namespace rows leak by numeric collision
      # (AmendmentRequest/5, Encounter/5 for a patient-5 token). A value in a
      # column is not a security boundary; that is the exact defect this PR
      # exists to close, and it recurred inside the fix. The compartment keys
      # on entity TYPE as well.
      #
      # Deliberately the PROVABLY-attributable subset: a row of some other
      # resource type ABOUT this patient (an Observation read, say) is not
      # reliably linked to the patient DFN by this schema — entity_identifier
      # there is the resource's own id or nil. Rather than guess and risk
      # leaking a foreign row, the patient-facing view returns only rows it can
      # prove belong to them. Completing the §164.528 accounting with a real
      # patient reference on every clinical audit row is a schema change that
      # belongs with the audit-model work (#507 Part 1 / #510), not a looser
      # filter here.
      #
      # Applied to the QUERY, not checked against a parameter — otherwise the
      # binding would govern which patient is named and not which rows return.
      def scoped_events
        return AuditEvent.all unless patient_context_scope?

        # A patient-scoped token with NO bound patient (resource_owner_id nil —
        # mintable today via client_credentials) has an EMPTY compartment, not
        # an unlimited one. Falling through to .all here was a fail-open on
        # #show: #index is refused earlier by authorize_patient_search!, but
        # #show reached this scope directly and returned any foreign row.
        # An unanswerable compartment question is an empty result — rendered as
        # 404 by #show, consistent with B6's uniform not-found posture.
        dfn = bound_patient_dfn
        return AuditEvent.none if dfn.blank?

        AuditEvent.where(entity_type: PATIENT_ENTITY_TYPE, entity_identifier: dfn)
      end

      def bound_patient_dfn
        return nil unless patient_context_scope?

        current_token.resource_owner_id.to_s
      end
    end
  end
end
