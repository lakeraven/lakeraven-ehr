# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequestsController < ApplicationController
      include PatientCompartment

      # One megabyte. Checked on the raw body before it is parsed.
      MAX_INTAKE_BYTES = 1_048_576

      compartment_bound :index, param: :patient, require_param: true
      # Create is not a compartment search. A system token has no RPMS
      # connection (ADR 0011); only system/ ServiceRequest create is accepted,
      # and any patient/ scope on that token is refused.
      before_action :authorize_system_intake!, only: :create

      def index
        dfn = patient_compartment_dfn
        results = ServiceRequest.for_patient(dfn)
        render_bundle_egress(results.map { |r| ServiceRequest.from_rpms_row(r, patient_dfn: dfn).to_fhir })
      end

      def create
        resource = intake_resource
        return if performed?

        render_intake(InboundReferralIntake.call(resource, current_token.application))
      end

      private

      # Also runs when a withheld capability answers before this before_action.
      def authorize_before_unavailable!
        super
        authorize_system_intake! if action_name == "create"
      end

      def authorize_system_intake!
        return if performed?

        allowed = scope_permits?(fhir_resource_type, write_permission, contexts: %w[system])
        return if allowed && !patient_context_scope?

        render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
      end

      def intake_resource
        body = request.raw_post.to_s
        return refuse_intake_body(:content_too_large, "too-costly") if body.bytesize > MAX_INTAKE_BYTES

        parse_intake_body(body)
      end

      def parse_intake_body(body)
        parsed = JSON.parse(body)
        return parsed if parsed.is_a?(Hash)

        refuse_intake_body(:bad_request, "structure")
        nil
      rescue JSON::ParserError
        refuse_intake_body(:bad_request, "invalid")
        nil
      end

      def refuse_intake_body(status, code)
        render_operation_outcome(status: status, severity: "error", code: code, diagnostics: "request body")
      end

      def render_intake(result)
        case result.status
        when :created then render_fhir(result.referral.to_fhir, status: :created)
        when :replayed then render_fhir(result.referral.to_fhir, status: :ok)
        when :conflict then render_intake_conflict
        when :invalid then render_invalid_intake(result)
        end
      end

      def render_intake_conflict
        render_operation_outcome(
          status: :conflict, severity: "error", code: "conflict", diagnostics: "ServiceRequest.identifier"
        )
      end

      def render_invalid_intake(result)
        issues = result.diagnostics.map { |path| { severity: "error", code: "invalid", diagnostics: path } }
        render json: { resourceType: "OperationOutcome", issue: issues },
               status: :unprocessable_content, content_type: FHIR_CONTENT_TYPE
        note_audit_denial("fhir operation refused: invalid (HTTP #{response.status})")
      end
    end
  end
end
