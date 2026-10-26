# frozen_string_literal: true

module Lakeraven
  module EHR
    # Controller declaration for #498. `rate_limit only:` registers the
    # route keys the convention test reads and, unless the action is enforced
    # by LoginThrottle, refuses over-limit requests before authentication or
    # any record lookup. Rails' `rate_limit` takes one `by:` key and reads
    # `config.cache_store`, which this engine cannot rely on, so the counters
    # live on Lakeraven::EHR::RateLimit.
    module RateLimitable
      extend ActiveSupport::Concern

      FHIR_THROTTLE_TYPE = "application/fhir+json"

      class_methods do
        def rate_limit(only:, login_throttle: false)
          Array(only).each { |action| RateLimit.register(controller_path, action) }
          return if login_throttle

          prepend_before_action :enforce_rate_limit!, only: Array(only)
        end
      end

      private

      def enforce_rate_limit!
        return if RateLimit.permit?(identity: rate_limit_identity, ip: request.remote_ip.to_s)

        rate_limit_write_audit!
        rate_limit_render!
      end

      def rate_limit_write_audit!
        note_audit_denial(RateLimit::AUDIT_DESCRIPTION) if respond_to?(:note_audit_denial, true)
        AuditEvent.create!(rate_limit_audit_attributes)
        @audit_recorded = true
      end

      def rate_limit_audit_attributes
        {
          event_type: "security",
          action: rate_limit_audit_action,
          outcome: "4",
          outcome_desc: RateLimit::AUDIT_DESCRIPTION,
          entity_type: rate_limit_entity_type,
          agent_who_type: "Unknown",
          agent_network_address: request.remote_ip.to_s
        }
      end

      def rate_limit_audit_action
        case request.request_method
        when "GET", "HEAD", "OPTIONS" then "R"
        when "POST" then "C"
        when "PUT", "PATCH" then "U"
        when "DELETE" then "D"
        else "E"
        end
      end

      def rate_limit_entity_type
        self.class.name.demodulize.delete_suffix("Controller").singularize
      end

      def rate_limit_render!
        if rate_limit_fhir_response?
          render json: rate_limit_operation_outcome, status: :too_many_requests, content_type: FHIR_THROTTLE_TYPE
        else
          render plain: "Too Many Requests", status: :too_many_requests
        end
        response.set_header("Retry-After", RateLimit.retry_after.to_s)
      end

      def rate_limit_operation_outcome
        {
          resourceType: "OperationOutcome",
          issue: [ { severity: "error", code: "throttled", diagnostics: "Too many requests" } ]
        }
      end

      def rate_limit_fhir_response?
        return true if is_a?(ApplicationController)
        return fhir_requested? if respond_to?(:fhir_requested?, true)

        false
      end

      def rate_limit_identity
        rate_limit_bearer || rate_limit_client || rate_limit_access_code || rate_limit_session_user
      end

      def rate_limit_bearer
        token = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
        token.present? ? "bearer:#{token}" : nil
      end

      def rate_limit_client
        client_id = rate_limit_string(:client_id)
        assertion = rate_limit_string(:client_assertion)
        return nil if client_id.nil? && assertion.nil?

        "client:#{client_id}:#{assertion}"
      end

      def rate_limit_access_code
        return nil unless controller_path == "lakeraven/ehr/sessions" && action_name == "create"

        code = rate_limit_string(:username)
        code && "access:#{code}"
      end

      def rate_limit_session_user
        duz = session[:duz].to_s.presence
        duz && "session:#{duz}"
      rescue StandardError
        nil
      end

      def rate_limit_string(name)
        value = params[name]
        value.is_a?(String) ? value.presence : nil
      end
    end
  end
end
