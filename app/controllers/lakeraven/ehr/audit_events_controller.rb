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

      # A patient-bound token sees only rows about its own patient. The
      # compartment filter is applied to the QUERY, not just checked against a
      # parameter — otherwise the binding would govern which patient is named
      # and not which rows come back.
      def scoped_events
        dfn = bound_patient_dfn
        return AuditEvent.all if dfn.blank?

        AuditEvent.where(entity_identifier: dfn)
      end

      def bound_patient_dfn
        return nil unless patient_context_scope?

        current_token.resource_owner_id.to_s
      end
    end
  end
end
