# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequestsController < ApplicationController
      include PatientCompartment

      # One megabyte. Content-Length is checked before the body is read;
      # the raw body is checked again after it is read.
      MAX_INTAKE_BYTES = 1_048_576

      # application/json is accepted so a client that cannot send fhir+json
      # can still post. Anything else is refused before the body is read.
      ACCEPTED_INTAKE_MEDIA_TYPES = %w[application/fhir+json application/json].freeze

      compartment_bound :index, param: :patient, require_param: true
      # Create is not a compartment search. A system token has no RPMS
      # connection (ADR 0011). The create permission must come from a system/
      # scope, and the token must carry no patient/ and no user/ scope.
      before_action :authorize_system_intake!, only: :create
      before_action :guard_intake_body!, only: :create

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

      # Create is a FHIR write. A not-supported answer is an OperationOutcome,
      # including when the client sends a browser Accept header.
      def feature_unavailable_html?
        return false if action_name == "create"

        super
      end

      def authorize_system_intake!
        return if performed?
        return if system_intake_permitted?

        render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
      end

      def system_intake_permitted?
        scope_permits?(fhir_resource_type, write_permission, contexts: %w[system]) &&
          !patient_context_scope? && !user_context_scope?
      end

      # Media type, then Transfer-Encoding, then Content-Length, before raw_post.
      # 411 only when Transfer-Encoding is still present. Puma de-chunks and
      # sets Content-Length before the app; the size limit applies instead.
      # Clients should send Content-Length.
      def guard_intake_body!
        return if performed?
        return refuse_intake_body(:unsupported_media_type, "not-supported") unless accepted_intake_media_type?
        return refuse_intake_body(:length_required, "structure") if transfer_encoded_intake?
        return if declared_content_length <= MAX_INTAKE_BYTES

        refuse_intake_body(:content_too_large, "too-costly")
      end

      def accepted_intake_media_type?
        ACCEPTED_INTAKE_MEDIA_TYPES.include?(request.media_type)
      end

      def transfer_encoded_intake?
        request.has_header?(ActionDispatch::Request::TRANSFER_ENCODING)
      end

      def declared_content_length
        request.get_header("CONTENT_LENGTH").to_i
      end

      def intake_resource
        raw = request.raw_post.to_s
        return refuse_intake_body(:content_too_large, "too-costly") if raw.bytesize > MAX_INTAKE_BYTES

        body = raw.dup.force_encoding(Encoding::UTF_8)
        return refuse_intake_body(:bad_request, "invalid") unless body.valid_encoding?

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
        # Queue id for the audit row, when this result created or replayed one.
        @intake_public_id = result.referral&.public_id
        case result.status
        when :created then render_fhir_egress(result.referral.to_fhir, status: :created)
        when :replayed then render_fhir_egress(result.referral.to_fhir, status: :ok)
        when :conflict then render_intake_conflict
        when :invalid then render_invalid_intake(result)
        end
      end

      # Create does not read the query string. ?patient= and ?id= would name
      # a record this intake never touched. Index keeps the shared rule.
      # The audited entity is ServiceRequest plus the queue id set above,
      # passed through the shared sanitizer.
      def audit_entity_reference
        return super unless action_name == "create"

        [ "ServiceRequest", sanitize_identifier_for(fhir_resource_type, @intake_public_id) ]
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
