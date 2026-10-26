# frozen_string_literal: true

require "base64"
require "json"

module Lakeraven
  module EHR
    # Controller declaration for #498. `rate_limit only:` registers the
    # route keys the convention test reads and refuses over-limit requests
    # before authentication or any record lookup. Calls accumulate: Rails
    # de-duplicates before_actions by name, so one callback checks the
    # per-class action set instead of installing a filter per declaration.
    #
    # `login_throttle: true` marks sessions#create, which LoginThrottle also
    # guards. The flag does not skip this limiter — that action is enforced
    # by both. Rails' own `rate_limit` takes one `by:` key and reads
    # `config.cache_store`, which this engine cannot rely on, so the counters
    # live on Lakeraven::EHR::RateLimit.
    module RateLimitable
      extend ActiveSupport::Concern

      FHIR_THROTTLE_TYPE = "application/fhir+json"

      class_methods do
        def rate_limit(only:, login_throttle: false)
          register_limited_actions(only)
          install_rate_limit_enforcement!
          @login_throttle_companion = true if login_throttle
        end

        def rate_limited_actions
          @rate_limited_actions ||= []
        end

        def rate_limited_action?(action)
          rate_limited_actions.include?(action.to_s)
        end

        def register_limited_actions(only)
          RateLimit.observe_controller(self)
          Array(only).map(&:to_s).each do |action|
            RateLimit.register(controller_path, action)
            rate_limited_actions << action unless rate_limited_actions.include?(action)
          end
        end

        def install_rate_limit_enforcement!
          return if @rate_limit_enforcement_installed

          @rate_limit_enforcement_installed = true
          prepend_before_action :enforce_rate_limit!
        end
      end

      private

      def enforce_rate_limit!
        return unless self.class.rate_limited_action?(action_name)

        principal = rate_limit_principal
        ip = ClientIp.resolve(request)
        return if RateLimit.permit?(identity: principal&.dig(:key), ip: ip)

        rate_limit_audit!(principal, ip)
        rate_limit_render!
      end

      def rate_limit_audit!(principal, ip)
        note_audit_denial(RateLimit::AUDIT_DESCRIPTION) if respond_to?(:note_audit_denial, true)
        persist_rate_limit_audit(principal, ip) if RateLimit.audit_due?(identity: principal&.dig(:key), ip: ip)
        # The fail-closed clinical wrapper would turn a missed audit into 503.
        # A throttle still answers 429, including when the insert fails or this
        # key was already audited for the window.
        @audit_recorded = true
      end

      def persist_rate_limit_audit(principal, ip)
        ActiveRecord::Base.transaction(requires_new: true) do
          AuditEvent.create!(rate_limit_audit_attributes(principal, ip))
        end
      rescue StandardError => error
        Rails.logger.error("[rate_limit] throttle audit failed: #{error.class}")
      end

      def rate_limit_audit_attributes(principal, ip)
        {
          event_type: "security",
          action: rate_limit_audit_action,
          outcome: "4",
          outcome_desc: RateLimit::AUDIT_DESCRIPTION,
          entity_type: rate_limit_entity_type,
          agent_who_type: "Unknown",
          agent_who_identifier: rate_limit_identity_digest(principal),
          agent_network_address: ip.to_s
        }
      end

      # SHA-256 of the raw identity (token, access code, or client id). The
      # hex is a non-reversible prefix for correlation; the secret itself
      # never lands on the row.
      def rate_limit_identity_digest(principal)
        secret = principal&.dig(:secret)
        return if secret.blank?

        Digest::SHA256.hexdigest(secret)
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

      def rate_limit_principal
        if backend_services_token?
          token_principal
        else
          bearer_principal || access_code_principal || session_principal
        end
      end

      def backend_services_token?
        controller_path == "lakeraven/ehr/backend_services" && action_name == "token"
      end

      # client_id, or the assertion's iss when client_id was not sent.
      # The payload is decoded only to read iss — the signature is not
      # checked, and the assertion string is never the throttle identity.
      def token_principal
        client_id = rate_limit_string(:client_id)
        return rate_limit_named("client", client_id) if client_id

        rate_limit_named("client", jwt_issuer(rate_limit_string(:client_assertion)))
      end

      def bearer_principal
        token = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
        rate_limit_named("bearer", token)
      end

      def access_code_principal
        return unless controller_path == "lakeraven/ehr/sessions" && action_name == "create"

        rate_limit_named("access", rate_limit_string(:username))
      end

      def session_principal
        rate_limit_named("session", session[:duz].to_s.presence)
      rescue StandardError
        nil
      end

      def rate_limit_named(kind, value)
        return if value.blank?

        { key: "#{kind}:#{value}", secret: value.to_s }
      end

      def jwt_issuer(assertion)
        payload = jwt_payload(assertion)
        return unless payload.is_a?(Hash)

        payload["iss"].to_s.presence
      end

      def jwt_payload(assertion)
        segment = assertion.to_s.split(".", 3)[1]
        return if segment.blank?

        JSON.parse(Base64.decode64(base64_pad(segment)))
      rescue ArgumentError, JSON::ParserError
        nil
      end

      def base64_pad(segment)
        padded = segment.tr("-_", "+/")
        padded + ("=" * ((4 - (padded.length % 4)) % 4))
      end

      def rate_limit_string(name)
        value = params[name]
        value.is_a?(String) ? value.presence : nil
      end
    end
  end
end
